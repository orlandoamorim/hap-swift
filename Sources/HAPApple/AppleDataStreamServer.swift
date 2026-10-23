// AppleDataStreamServer.swift
// Copyright 2026 Monagle Pty Ltd

#if canImport(Network)
import Foundation
import Network
import Logging
import HAPCore
import HAPTransport

// MARK: - Recording source

/// One piece of a HomeKit Secure Video recording: the fragmented MP4 initialization
/// segment, then media fragments (moof + mdat).
public enum DataStreamPacket: Sendable {
    case initialization(Data)
    case fragment(Data, isLast: Bool)
}

/// Produces the recording for a `dataSend` stream the controller opened. The stream
/// is cancelled when the controller closes it.
public typealias DataStreamRecordingSource = @Sendable (_ streamID: Int64) -> AsyncThrowingStream<DataStreamPacket, Error>

// MARK: - AppleDataStreamServer

/// HomeKit Data Stream (HDS) over TCP, the channel HomeKit Secure Video clips go
/// through. A controller writes SetupDataStreamTransport on its HAP connection;
/// `prepare` derives keys from that connection's pair-verify secret and returns the
/// port and salt to answer with. The controller then connects, says hello and opens
/// `ipcamera.recording` streams.
public actor AppleDataStreamServer {
    /// Largest data chunk in one `dataSend.data` event.
    static let maxChunk = 0x40000
    /// How long a prepared session waits for the controller to connect.
    static let pendingTimeout: Duration = .seconds(10)

    private let recording: DataStreamRecordingSource
    private let logger: Logger
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var pending: [(keys: DataStreamKeys, expires: ContinuousClock.Instant)] = []
    private var connections: [ObjectIdentifier: DataStreamConnection] = [:]

    public init(logger: Logger = Logger(label: "hap.datastream"), recording: @escaping DataStreamRecordingSource) {
        self.logger = logger
        self.recording = recording
    }

    /// Prepares a session for the controller on the HAP connection with `sharedSecret`.
    public func prepare(sharedSecret: Data, controllerKeySalt: Data) async throws -> (port: UInt16, accessoryKeySalt: Data) {
        try await startListener()
        let accessoryKeySalt = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
        let now = ContinuousClock.now
        pending.removeAll { $0.expires < now }
        pending.append((DataStreamKeys(sharedSecret: sharedSecret, controllerKeySalt: controllerKeySalt,
                                       accessoryKeySalt: accessoryKeySalt), now + Self.pendingTimeout))
        return (port, accessoryKeySalt)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { connection in Task { await connection.close() } }
        connections = [:]
    }

    /// Takes the pending session whose keys open the controller's first frame.
    func claim(firstFrame frame: Data) -> DataStreamCipher? {
        let now = ContinuousClock.now
        pending.removeAll { $0.expires < now }
        for (index, session) in pending.enumerated() {
            var cipher = DataStreamCipher(keys: session.keys)
            if (try? cipher.open(frame)) != nil {
                pending.remove(at: index)
                // Re-open from a fresh cipher so the caller decrypts the frame itself.
                return DataStreamCipher(keys: session.keys)
            }
        }
        return nil
    }

    func removed(_ id: ObjectIdentifier) {
        connections[id] = nil
    }

    // MARK: - Listener

    private func startListener() async throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let box = OneShot()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.continuation = continuation
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(nil)
                case .failed(let error): box.resume(error)
                case .cancelled: box.resume(HAPError.unavailable)
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        self.listener = listener
        port = listener.port?.rawValue ?? 0
        logger.info("HomeKit Data Stream listening on port \(port)")
    }

    private func accept(_ nw: NWConnection) {
        let connection = DataStreamConnection(connection: nw, server: self, recording: recording, logger: logger)
        connections[ObjectIdentifier(connection)] = connection
        Task { await connection.start() }
    }
}

/// Resumes a continuation once; NWListener reports several states over its lifetime.
private final class OneShot: @unchecked Sendable {
    // Only touched from the listener's serial queue after being set.
    var continuation: CheckedContinuation<Void, Error>?

    func resume(_ error: Error?) {
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}

// MARK: - Connection

actor DataStreamConnection {
    private let connection: NWConnection
    private weak var server: AppleDataStreamServer?
    private let recording: DataStreamRecordingSource
    private let logger: Logger
    private var cipher: DataStreamCipher?
    private var buffer = Data()
    private var streams: [Int64: Task<Void, Never>] = [:]

    init(connection: NWConnection, server: AppleDataStreamServer, recording: @escaping DataStreamRecordingSource, logger: Logger) {
        self.connection = connection
        self.server = server
        self.recording = recording
        self.logger = logger
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.close() }
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    func close() async {
        streams.values.forEach { $0.cancel() }
        streams = [:]
        connection.cancel()
        await server?.removed(ObjectIdentifier(self))
    }

    private nonisolated func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else { return }
                if let data, !data.isEmpty { await self.received(data) }
                if isComplete || error != nil {
                    await self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func received(_ data: Data) async {
        buffer.append(data)
        while let length = DataStreamCipher.frameLength(in: buffer), buffer.count >= length {
            let frame = buffer.prefix(length)
            buffer = Data(buffer.dropFirst(length))
            if cipher == nil {
                cipher = await server?.claim(firstFrame: Data(frame))
                guard cipher != nil else {
                    logger.warning("HDS: first frame matches no prepared session; closing")
                    await close()
                    return
                }
            }
            do {
                guard let payload = try cipher?.open(Data(frame)) else { return }
                await handle(try DataStreamMessage(decoding: payload))
            } catch {
                logger.warning("HDS: bad frame: \(error)")
                await close()
                return
            }
        }
    }

    // MARK: - Protocol

    private func handle(_ message: DataStreamMessage) async {
        logger.debug("HDS ← \(message.protocol).\(message.topic) \(message.kind)")
        switch (message.protocol, message.topic, message.kind) {
        case ("control", "hello", .request(let id)):
            await send(DataStreamMessage(protocol: "control", topic: "hello", kind: .response(id: id, status: 0)))
        case ("dataSend", "open", .request(let id)):
            guard let streamID = message.message["streamId"]?.intValue,
                  message.message["type"]?.stringValue == "ipcamera.recording" else {
                await send(DataStreamMessage(protocol: "dataSend", topic: "open", kind: .response(id: id, status: 6),
                                             message: .dictionary(["status": .int(4)])))
                return
            }
            await send(DataStreamMessage(protocol: "dataSend", topic: "open", kind: .response(id: id, status: 0),
                                         message: .dictionary(["status": .int(0)])))
            streams[streamID]?.cancel()
            streams[streamID] = Task { await self.stream(streamID) }
        case ("dataSend", "close", .event), ("dataSend", "ack", .event):
            if let streamID = message.message["streamId"]?.intValue {
                logger.info("HDS: stream \(streamID) \(message.topic) (reason \(message.message["reason"]?.intValue ?? 0))")
                streams.removeValue(forKey: streamID)?.cancel()
            }
        case (_, _, .request(let id)):
            await send(DataStreamMessage(protocol: message.protocol, topic: message.topic, kind: .response(id: id, status: 5)))
        default:
            break
        }
    }

    /// Sends the recording as `dataSend.data` events, in chunks of up to 256 KiB.
    private func stream(_ streamID: Int64) async {
        logger.info("HDS: recording stream \(streamID) opened")
        var sequence: Int64 = 0
        var ended = false
        do {
            for try await packet in recording(streamID) {
                sequence += 1
                let (data, type, last): (Data, String, Bool) = switch packet {
                case .initialization(let data): (data, "mediaInitialization", false)
                case .fragment(let data, let isLast): (data, "mediaFragment", isLast)
                }
                var chunk: Int64 = 0
                var offset = 0
                repeat {
                    chunk += 1
                    let end = min(offset + AppleDataStreamServer.maxChunk, data.count)
                    let isLastChunk = end == data.count
                    var metadata: [String: HDSValue] = [
                        "dataType": .string(type), "dataSequenceNumber": .int(sequence),
                        "dataChunkSequenceNumber": .int(chunk), "isLastDataChunk": .bool(isLastChunk),
                    ]
                    if chunk == 1 { metadata["dataTotalSize"] = .int(Int64(data.count)) }
                    var event: [String: HDSValue] = [
                        "streamId": .int(streamID),
                        "packets": .array([.dictionary(["data": .data(data.subdata(in: offset ..< end)), "metadata": .dictionary(metadata)])]),
                    ]
                    if isLastChunk && last { event["endOfStream"] = .bool(true) }
                    await send(DataStreamMessage(protocol: "dataSend", topic: "data", kind: .event, message: .dictionary(event)))
                    offset = end
                } while offset < data.count
                if last { ended = true; break }
            }
            // The source stopped early (its camera stream restarted): tell the controller.
            if !ended, !Task.isCancelled {
                await send(DataStreamMessage(protocol: "dataSend", topic: "close", kind: .event,
                                             message: .dictionary(["streamId": .int(streamID), "reason": .int(0)])))
            }
        } catch {
            if !Task.isCancelled {
                logger.warning("HDS: recording stream \(streamID) failed: \(error)")
                await send(DataStreamMessage(protocol: "dataSend", topic: "close", kind: .event,
                                             message: .dictionary(["streamId": .int(streamID), "reason": .int(5)])))
            }
        }
        logger.info("HDS: recording stream \(streamID) finished after \(sequence) packet(s)")
    }

    private func send(_ message: DataStreamMessage) async {
        guard var cipher, let frame = try? cipher.seal(message.encoded()) else { return }
        self.cipher = cipher
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: frame, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
#endif

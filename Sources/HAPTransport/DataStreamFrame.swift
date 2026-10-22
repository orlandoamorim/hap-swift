// DataStreamFrame.swift
// Copyright 2026 Monagle Pty Ltd

import Crypto
import Foundation
import HAPCrypto

// MARK: - Keys

/// Keys of one HomeKit Data Stream connection, derived from the pair-verify shared
/// secret of the HAP connection that wrote SetupDataStreamTransport.
public struct DataStreamKeys: Sendable {
    /// Decrypts frames from the controller ("HDS-Write-Encryption-Key").
    public let controllerToAccessory: SymmetricKey
    /// Encrypts frames to the controller ("HDS-Read-Encryption-Key").
    public let accessoryToController: SymmetricKey

    public init(sharedSecret: Data, controllerKeySalt: Data, accessoryKeySalt: Data) {
        let salt = controllerKeySalt + accessoryKeySalt
        controllerToAccessory = HAPKeyDerivation.deriveKey(
            inputKeyMaterial: sharedSecret, salt: salt, info: Data("HDS-Write-Encryption-Key".utf8))
        accessoryToController = HAPKeyDerivation.deriveKey(
            inputKeyMaterial: sharedSecret, salt: salt, info: Data("HDS-Read-Encryption-Key".utf8))
    }
}

// MARK: - Frames

/// HDS frame: 1-byte type (1), 24-bit big-endian payload length, then the
/// ChaCha20-Poly1305 ciphertext and tag. The 4-byte header is the AAD and each
/// direction counts its own nonce from 0.
public struct DataStreamCipher: Sendable {
    public static let headerLength = 4
    public static let tagLength = 16

    private let keys: DataStreamKeys
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0

    public init(keys: DataStreamKeys) {
        self.keys = keys
    }

    public mutating func seal(_ payload: Data) throws -> Data {
        let n = payload.count
        let header = Data([0x01, UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        let sealed = try HAPEncryption.encrypt(
            plaintext: payload, key: keys.accessoryToController,
            nonce: HAPEncryption.buildNonce(counter: writeCounter), aad: header)
        writeCounter += 1
        return header + sealed
    }

    /// Length of the whole frame at the start of `buffer`, or nil until its header has arrived.
    public static func frameLength(in buffer: Data) -> Int? {
        guard buffer.count >= headerLength else { return nil }
        let b = buffer.startIndex
        let length = Int(buffer[b + 1]) << 16 | Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
        return headerLength + length + tagLength
    }

    /// Decrypts one complete frame. The counter only advances when it opens.
    public mutating func open(_ frame: Data) throws -> Data {
        let frame = Data(frame)
        let header = frame.prefix(Self.headerLength)
        let payload = try HAPEncryption.decrypt(
            ciphertext: frame.dropFirst(Self.headerLength), key: keys.controllerToAccessory,
            nonce: HAPEncryption.buildNonce(counter: readCounter), aad: header)
        readCounter += 1
        return payload
    }
}

// MARK: - Messages

/// One HDS message: a header dictionary (`protocol` plus `request`/`response`/`event`)
/// and a message dictionary. Payload = header length (1 byte), header, message.
public struct DataStreamMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case request(id: Int64)
        case response(id: Int64, status: Int64)
        case event
    }

    public var `protocol`: String
    public var topic: String
    public var kind: Kind
    public var message: HDSValue

    public init(protocol: String, topic: String, kind: Kind, message: HDSValue = .dictionary([:])) {
        self.protocol = `protocol`
        self.topic = topic
        self.kind = kind
        self.message = message
    }

    public func encoded() -> Data {
        var header: [String: HDSValue] = ["protocol": .string(`protocol`)]
        switch kind {
        case .request(let id):
            header["request"] = .string(topic)
            header["id"] = .int(id)
        case .response(let id, let status):
            header["response"] = .string(topic)
            header["id"] = .int(id)
            header["status"] = .int(status)
        case .event:
            header["event"] = .string(topic)
        }
        let headerData = DataStreamCodec.encode(.dictionary(header))
        return Data([UInt8(headerData.count)]) + headerData + DataStreamCodec.encode(message)
    }

    public init(decoding payload: Data) throws {
        let payload = Data(payload)
        guard let length = payload.first.map(Int.init), payload.count >= 1 + length else { throw HDSCodecError.truncated }
        let header = try DataStreamCodec.decode(payload.subdata(in: 1 ..< 1 + length))
        let rest = payload.subdata(in: 1 + length ..< payload.count)
        message = rest.isEmpty ? .dictionary([:]) : try DataStreamCodec.decode(rest)
        `protocol` = header["protocol"]?.stringValue ?? ""
        if let topic = header["request"]?.stringValue {
            self.topic = topic
            kind = .request(id: header["id"]?.intValue ?? 0)
        } else if let topic = header["response"]?.stringValue {
            self.topic = topic
            kind = .response(id: header["id"]?.intValue ?? 0, status: header["status"]?.intValue ?? 0)
        } else {
            topic = header["event"]?.stringValue ?? ""
            kind = .event
        }
    }
}

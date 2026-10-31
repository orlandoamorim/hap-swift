// HAPBridge.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import Logging

// MARK: - HAPBridge

public actor HAPBridge {
    private let logger = Logger(label: "hap.bridge")
    private var accessories: [UInt64: HAPAccessory] = [:]
    private var nextAID: UInt64 = 2
    private var writeHandlers: [String: @Sendable (HAPCharacteristicValue) async throws -> Void] = [:]
    private var writeResponseHandlers: [String: WriteResponseHandler] = [:]
    private var resourceHandlers: [UInt64: ResourceHandler] = [:]
    public let category: HAPCategory

    // MARK: - Configuration number (c#)

    /// HAP configuration number — incremented when the accessory database changes.
    /// Persisted across restarts so paired iOS devices know to re-read /accessories.
    private var configurationNumber: Int = 1

    /// The current configuration number for mDNS advertisement.
    public var currentConfigurationNumber: Int { configurationNumber }

    /// Restore a previously persisted configuration number (call before adding accessories).
    public func restoreConfigurationNumber(_ n: Int) {
        configurationNumber = max(1, n)
    }

    /// Reserve an AID so auto-assignment skips it.
    ///
    /// Call before provisioning to prevent new accessories from being
    /// auto-assigned AIDs that belong to existing device map entries.
    public func reserveAID(_ aid: UInt64) {
        if aid >= nextAID {
            nextAID = aid + 1
        }
    }

    // MARK: - Accessory change handlers

    /// Callbacks fired when the accessory database changes (add/remove).
    /// Parameter is the new configuration number.
    private var accessoryChangeHandlers: [@Sendable (Int) async -> Void] = []

    /// Register a handler called when accessories are added or removed.
    /// Multiple handlers can be registered (e.g., re-advertisement + persistence).
    public func addAccessoryChangeHandler(_ handler: @escaping @Sendable (Int) async -> Void) {
        accessoryChangeHandlers.append(handler)
    }

    // MARK: - Batch updates

    private var isBatching = false
    private var batchDirty = false

    /// Begin a batch update — suppresses c# increment and change notifications
    /// until ``endBatchUpdate()`` is called.
    public func beginBatchUpdate() {
        isBatching = true
        batchDirty = false
    }

    /// End a batch update — increments c# once and fires change handlers if
    /// any accessories were added or removed during the batch.
    public func endBatchUpdate() async {
        isBatching = false
        guard batchDirty else { return }
        batchDirty = false
        configurationNumber += 1
        await notifyAccessoryChange()
    }

    private func incrementAndNotify() async {
        if isBatching {
            batchDirty = true
        } else {
            configurationNumber += 1
            await notifyAccessoryChange()
        }
    }

    private func notifyAccessoryChange() async {
        let cn = configurationNumber
        for handler in accessoryChangeHandlers {
            await handler(cn)
        }
    }

    // MARK: - Event subscriptions

    /// Maps "aid.iid" → set of connection IDs that subscribed to events.
    private var subscriptions: [String: Set<Int>] = [:]

    /// Called when a characteristic value changes and subscribers exist.
    /// Parameters: set of connection IDs, serialised EVENT/1.0 payload (pre-JSON,
    /// needs encryption per-connection).
    private var onCharacteristicChange: (@Sendable (_ subscribers: Set<Int>, _ eventData: Data) async -> Void)?

    /// Set the handler called when a subscribed characteristic value changes.
    public func setCharacteristicChangeHandler(
        _ handler: @escaping @Sendable (_ subscribers: Set<Int>, _ eventData: Data) async -> Void
    ) {
        onCharacteristicChange = handler
    }

    private static func handlerKey(aid: UInt64, iid: UInt64) -> String {
        "\(aid).\(iid)"
    }

    public init(info: AccessoryInfo, category: HAPCategory = .bridge) {
        self.category = category

        // Bridge itself is AID=1
        let infoService = HAPService.accessoryInformation(
            name: info.name,
            manufacturer: info.manufacturer,
            model: info.model,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            startIID: 1
        )

        let protocolService = HAPService.protocolInformation(startIID: 8)
        let bridge = HAPAccessory(aid: 1, services: [infoService, protocolService])
        self.accessories[1] = bridge
    }

    // MARK: - Standalone accessory

    /// Adds services to AID 1, for a standalone (non-bridge) accessory such as an
    /// IP camera, which HomeKit hubs don't stream from behind a bridge.
    /// Returns the services with their assigned IIDs.
    @discardableResult
    public func addPrimaryServices(_ services: [HAPService]) -> [HAPService] {
        guard var primary = accessories[1] else { return [] }
        var nextIID = (primary.services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }.max() ?? 0) + 1
        var added: [HAPService] = []
        for service in services {
            let serviceIID = nextIID
            nextIID += 1
            var chars: [HAPCharacteristic] = []
            for char in service.characteristics {
                chars.append(HAPCharacteristic(
                    iid: nextIID, type: char.type, value: char.value, permissions: char.permissions,
                    format: char.format, minValue: char.minValue, maxValue: char.maxValue,
                    minStep: char.minStep, unit: char.unit, validValues: char.validValues
                ))
                nextIID += 1
            }
            added.append(HAPService(iid: serviceIID, type: service.type, characteristics: chars, linked: service.linked))
        }
        added = Self.resolvingLinks(added)
        primary.services += added
        accessories[1] = primary
        return added
    }

    // MARK: - Accessory Management

    /// Add an accessory to the bridge.
    ///
    /// - Parameters:
    ///   - info: Accessory metadata (name, manufacturer, etc.).
    ///   - services: HAP services to expose (e.g., lightbulb, motion sensor).
    ///   - aid: Explicit accessory ID. When `nil`, auto-assigns the next available AID.
    ///          Use explicit AIDs for AID stability across restarts.
    /// - Returns: The assigned accessory ID.
    @discardableResult
    public func addAccessory(info: AccessoryInfo, services: [HAPService], aid: UInt64? = nil) async -> UInt64 {
        let aid: UInt64 = if let explicit = aid {
            explicit
        } else {
            { let a = nextAID; nextAID += 1; return a }()
        }

        // Keep nextAID ahead of any explicit AID to prevent collisions.
        if aid >= nextAID {
            nextAID = aid + 1
        }

        guard aid != 1 else {
            logger.warning("Cannot add accessory with AID=1 (reserved for bridge)")
            return aid
        }

        if accessories[aid] != nil {
            logger.warning("Replacing existing accessory at AID=\(aid)")
        }

        // Build accessory information service
        let infoService = HAPService.accessoryInformation(
            name: info.name,
            manufacturer: info.manufacturer,
            model: info.model,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            startIID: 1
        )

        // Assign IIDs to additional services.
        // Layout: infoService.iid=1, its N chars at 2..N+1,
        //         then service2.iid=N+2, its chars at N+3..., etc.
        var allServices = [infoService]
        var nextIID: UInt64 = infoService.iid + UInt64(infoService.characteristics.count) + 1
        for service in services {
            let serviceIID = nextIID
            nextIID += 1
            var updatedChars: [HAPCharacteristic] = []
            for char in service.characteristics {
                updatedChars.append(HAPCharacteristic(
                    iid: nextIID,
                    type: char.type,
                    value: char.value,
                    permissions: char.permissions,
                    format: char.format,
                    minValue: char.minValue,
                    maxValue: char.maxValue,
                    minStep: char.minStep,
                    unit: char.unit,
                    validValues: char.validValues
                ))
                nextIID += 1
            }
            allServices.append(HAPService(iid: serviceIID, type: service.type, characteristics: updatedChars, linked: service.linked))
        }
        allServices = [infoService] + Self.resolvingLinks(Array(allServices.dropFirst()))
        // Last IID, so adding it later doesn't move the IIDs the Home app already knows.
        if let configuredName = info.configuredName {
            allServices[0].characteristics.append(HAPCharacteristic(
                iid: nextIID, type: .configuredName, value: .string(configuredName),
                permissions: [.read, .write, .notify], format: .string
            ))
        }

        let accessory = HAPAccessory(aid: aid, services: allServices)
        accessories[aid] = accessory

        await incrementAndNotify()

        return aid
    }

    /// Turns `linked` from positions in `services` into the IIDs of those services.
    private static func resolvingLinks(_ services: [HAPService]) -> [HAPService] {
        services.map { service in
            var service = service
            service.linked = service.linked.compactMap { services.indices.contains(Int($0)) ? services[Int($0)].iid : nil }
            return service
        }
    }

    /// Remove an accessory from the bridge.
    ///
    /// Also cleans up associated write handlers and event subscriptions.
    /// The bridge accessory (AID=1) cannot be removed.
    public func removeAccessory(aid: UInt64) async {
        guard aid != 1 else { return }  // Cannot remove bridge
        guard accessories.removeValue(forKey: aid) != nil else { return }
        logger.warning("Removed accessory AID=\(aid). Remaining: \(accessories.keys.sorted())")

        // Clean up write handlers for this accessory
        let aidPrefix = "\(aid)."
        writeHandlers = writeHandlers.filter { !$0.key.hasPrefix(aidPrefix) }
        writeResponseHandlers = writeResponseHandlers.filter { !$0.key.hasPrefix(aidPrefix) }
        resourceHandlers[aid] = nil

        // Clean up event subscriptions for this accessory
        subscriptions = subscriptions.filter { !$0.key.hasPrefix(aidPrefix) }

        await incrementAndNotify()
    }

    // MARK: - Accessory Database

    public func accessoryDatabase() -> [HAPAccessory] {
        accessories.values.sorted { $0.aid < $1.aid }
    }

    // MARK: - Characteristic Access

    public func readCharacteristic(aid: UInt64, iid: UInt64) -> HAPCharacteristicValue? {
        guard let accessory = accessories[aid] else { return nil }
        for service in accessory.services {
            for characteristic in service.characteristics where characteristic.iid == iid {
                return characteristic.value
            }
        }
        return nil
    }

    /// Stores the value and runs the write handler. Returns the value of a write-response
    /// handler, for writes the controller sent with `"r": true`.
    @discardableResult
    public func writeCharacteristic(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue,
                                    connectionID: Int = 0) async throws -> HAPCharacteristicValue? {
        guard var accessory = accessories[aid] else {
            throw HAPError.notFound
        }

        var found = false
        for serviceIndex in 0 ..< accessory.services.count {
            for charIndex in 0 ..< accessory.services[serviceIndex].characteristics.count {
                if accessory.services[serviceIndex].characteristics[charIndex].iid == iid {
                    guard accessory.services[serviceIndex].characteristics[charIndex].isWritable else {
                        throw HAPError.readOnly
                    }
                    let char = accessory.services[serviceIndex].characteristics[charIndex]
                    accessory.services[serviceIndex].characteristics[charIndex].value = value.clamped(
                        minValue: char.minValue, maxValue: char.maxValue
                    )
                    found = true
                    break
                }
            }
            if found { break }
        }

        guard found else { throw HAPError.notFound }
        accessories[aid] = accessory

        let key = Self.handlerKey(aid: aid, iid: iid)
        if let handler = writeHandlers[key] {
            try await handler(value)
        }
        if let handler = writeResponseHandlers[key] {
            return try await handler(value, connectionID)
        }
        return nil
    }

    // MARK: - Write Handlers

    public func registerWriteHandler(
        aid: UInt64,
        iid: UInt64,
        handler: @escaping @Sendable (HAPCharacteristicValue) async throws -> Void
    ) {
        writeHandlers[Self.handlerKey(aid: aid, iid: iid)] = handler
    }

    /// Handles a write whose response carries a value (`wr` permission), such as
    /// SetupDataStreamTransport. Gets the ID of the connection that wrote.
    public typealias WriteResponseHandler = @Sendable (_ value: HAPCharacteristicValue, _ connectionID: Int) async throws -> HAPCharacteristicValue

    public func registerWriteResponseHandler(aid: UInt64, iid: UInt64, handler: @escaping WriteResponseHandler) {
        writeResponseHandlers[Self.handlerKey(aid: aid, iid: iid)] = handler
    }

    // MARK: - Resources (camera snapshots)

    /// Produces a JPEG snapshot for `POST /resource`, given the requested size.
    public typealias ResourceHandler = @Sendable (_ width: Int, _ height: Int) async throws -> Data

    /// Registers the snapshot source of a camera accessory.
    public func registerResourceHandler(aid: UInt64, handler: @escaping ResourceHandler) {
        resourceHandlers[aid] = handler
    }

    /// Snapshot for `aid`; `nil` when the accessory has no resource handler.
    public func resource(aid: UInt64, width: Int, height: Int) async throws -> Data? {
        guard let handler = resourceHandlers[aid] else { return nil }
        return try await handler(width, height)
    }

    // MARK: - Characteristic Updates

    public func updateCharacteristic(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue) {
        guard var accessory = accessories[aid] else { return }

        for serviceIndex in 0 ..< accessory.services.count {
            for charIndex in 0 ..< accessory.services[serviceIndex].characteristics.count {
                if accessory.services[serviceIndex].characteristics[charIndex].iid == iid {
                    let char = accessory.services[serviceIndex].characteristics[charIndex]
                    let clamped = value.clamped(minValue: char.minValue, maxValue: char.maxValue)
                    let oldValue = char.value
                    accessory.services[serviceIndex].characteristics[charIndex].value = clamped
                    accessories[aid] = accessory

                    // Notify subscribers if value changed
                    if oldValue != clamped {
                        notifySubscribers(aid: aid, iid: iid, value: clamped)
                    }
                    return
                }
            }
        }
    }

    // MARK: - Event Subscriptions

    public func subscribe(connectionID: Int, aid: UInt64, iid: UInt64) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        subscriptions[key, default: []].insert(connectionID)
        logger.debug("Event subscribe: connection \(connectionID) → aid=\(aid) iid=\(iid)")
    }

    public func unsubscribe(connectionID: Int, aid: UInt64, iid: UInt64) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        subscriptions[key]?.remove(connectionID)
    }

    /// Remove all subscriptions for a disconnected connection.
    // MARK: - Session secrets (HomeKit Data Stream)

    /// Pair-verify shared secret of each verified connection.
    private var sessionSecrets: [Int: Data] = [:]

    public func setSessionSecret(_ secret: Data?, connectionID: Int) {
        sessionSecrets[connectionID] = secret
    }

    public func sessionSecret(connectionID: Int) -> Data? {
        sessionSecrets[connectionID]
    }

    public func unsubscribeAll(connectionID: Int) {
        for key in subscriptions.keys {
            subscriptions[key]?.remove(connectionID)
        }
    }

    private func notifySubscribers(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        guard let subscribers = subscriptions[key], !subscribers.isEmpty else {
            logger.debug("Event notify: aid=\(aid) iid=\(iid) — no subscribers")
            return
        }
        guard let handler = onCharacteristicChange else {
            logger.warning("Event notify: aid=\(aid) iid=\(iid) — no handler set")
            return
        }

        logger.debug("Event notify: aid=\(aid) iid=\(iid) value=\(value) → \(subscribers.count) subscriber(s)")
        let eventData = Self.buildEventPayload(aid: aid, iid: iid, value: value)
        let subs = subscribers
        Task { await handler(subs, eventData) }
    }

    /// Build the raw HTTP bytes for a HAP EVENT/1.0 message.
    ///
    /// Format:
    /// ```
    /// EVENT/1.0 200 OK\r\n
    /// Content-Type: application/hap+json\r\n
    /// Content-Length: <len>\r\n
    /// \r\n
    /// {"characteristics":[{"aid":<aid>,"iid":<iid>,"value":<value>}]}
    /// ```
    private static func buildEventPayload(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue) -> Data {
        let jsonValue: Any = switch value {
        case .bool(let v): v
        case .uint8(let v): v
        case .uint16(let v): v
        case .uint32(let v): v
        case .int32(let v): v
        case .float(let v): v
        case .string(let v): v
        case .data(let v): v.base64EncodedString()
        case .tlv8(let v): v.base64EncodedString()
        }

        let charDict: [String: Any] = ["aid": aid, "iid": iid, "value": jsonValue]
        let body: [String: Any] = ["characteristics": [charDict]]
        let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        var event = "EVENT/1.0 200 OK\r\n"
        event += "Content-Type: application/hap+json\r\n"
        event += "Content-Length: \(jsonData.count)\r\n"
        event += "\r\n"

        var data = Data(event.utf8)
        data.append(jsonData)
        return data
    }
}

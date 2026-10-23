// HAPBridgeTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCore
@testable import HAPTransport

@Suite("HAPBridge Tests")
struct HAPBridgeTests {

    private func makeBridge() -> HAPBridge {
        HAPBridge(info: AccessoryInfo(
            name: "Test Bridge",
            manufacturer: "Acumen",
            model: "Bridge1",
            serialNumber: "001",
            firmwareRevision: "1.0.0"
        ))
    }

    @Test("bridge is AID=1")
    func bridgeIsAID1() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)
        #expect(db[0].aid == 1)
    }

    @Test("bridge has accessory information service")
    func bridgeHasInfo() async {
        let bridge = makeBridge()
        let db = await bridge.accessoryDatabase()
        #expect(db[0].services[0].type == .accessoryInformation)
        #expect(db[0].name == "Test Bridge")
    }

    @Test("add accessory assigns next AID")
    func addAccessoryAID() async {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = await bridge.addAccessory(
            info: AccessoryInfo(
                name: "Panel", manufacturer: "Acumen", model: "P1",
                serialNumber: "002", firmwareRevision: "1.0.0"
            ),
            services: [securityService]
        )
        #expect(aid == 2)

        let db = await bridge.accessoryDatabase()
        #expect(db.count == 2)
    }

    @Test("multiple accessories get sequential AIDs")
    func sequentialAIDs() async {
        let bridge = makeBridge()
        let aid1 = await bridge.addAccessory(
            info: AccessoryInfo(name: "A", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: []
        )
        let aid2 = await bridge.addAccessory(
            info: AccessoryInfo(name: "B", manufacturer: "M", model: "M", serialNumber: "2", firmwareRevision: "1.0"),
            services: []
        )
        #expect(aid1 == 2)
        #expect(aid2 == 3)
    }

    @Test("remove accessory")
    func removeAccessory() async {
        let bridge = makeBridge()
        let aid = await bridge.addAccessory(
            info: AccessoryInfo(name: "A", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: []
        )
        await bridge.removeAccessory(aid: aid)
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)  // Only bridge remains
    }

    @Test("cannot remove bridge")
    func cannotRemoveBridge() async {
        let bridge = makeBridge()
        await bridge.removeAccessory(aid: 1)
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)  // Bridge still there
    }

    @Test("read characteristic")
    func readCharacteristic() async {
        let bridge = makeBridge()
        // Service iid=1, name characteristic iid=2 (service occupies the startIID slot)
        let value = await bridge.readCharacteristic(aid: 1, iid: 2)
        #expect(value == .string("Test Bridge"))
    }

    @Test("write characteristic")
    func writeCharacteristic() async throws {
        let bridge = makeBridge()
        let securityService = HAPService.securitySystem(startIID: 1)
        let aid = await bridge.addAccessory(
            info: AccessoryInfo(name: "Panel", manufacturer: "M", model: "M", serialNumber: "1", firmwareRevision: "1.0"),
            services: [securityService]
        )

        // Find the targetSecuritySystemState IID (it's in the second service)
        let db = await bridge.accessoryDatabase()
        let accessory = db.first(where: { $0.aid == aid })!
        let secSvc = accessory.services.first(where: { $0.type == .securitySystem })!
        let targetChar = secSvc.characteristics.first(where: { $0.type == .targetSecuritySystemState })!

        try await bridge.writeCharacteristic(aid: aid, iid: targetChar.iid, value: .uint8(1))
        let written = await bridge.readCharacteristic(aid: aid, iid: targetChar.iid)
        #expect(written == .uint8(1))
    }

    @Test("resource handler serves snapshots per accessory and is removed with it")
    func resourceHandler() async throws {
        let bridge = makeBridge()
        let aid = await bridge.addAccessory(
            info: AccessoryInfo(name: "Cam", manufacturer: "m", model: "m", serialNumber: "s", firmwareRevision: "1"),
            services: [.switch(startIID: 0)]
        )
        await bridge.registerResourceHandler(aid: aid) { width, height in Data("\(width)x\(height)".utf8) }
        let jpeg = try await bridge.resource(aid: aid, width: 640, height: 360)
        #expect(jpeg == Data("640x360".utf8))
        #expect(try await bridge.resource(aid: 99, width: 1, height: 1) == nil)
        await bridge.removeAccessory(aid: aid)
        #expect(try await bridge.resource(aid: aid, width: 1, height: 1) == nil)
    }

    @Test("primary services go on AID 1 after the existing ones")
    func primaryServices() async {
        let bridge = HAPBridge(info: AccessoryInfo(name: "Cam", manufacturer: "m", model: "m", serialNumber: "s", firmwareRevision: "1"),
                               category: .ipCamera)
        let before = await bridge.accessoryDatabase()[0].services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }.max()!
        let added = await bridge.addPrimaryServices([.switch(startIID: 0), .switch(startIID: 0)])
        #expect(added.map(\.iid) == [before + 1, before + 3])
        #expect(added[1].characteristics[0].iid == before + 4)
        let db = await bridge.accessoryDatabase()
        #expect(db.count == 1)
        #expect(db[0].services.filter { $0.type == .switch }.count == 2)
        #expect(await bridge.category == .ipCamera)
    }

    @Test("linked services are given as positions and stored as IIDs")
    func linkedServices() async {
        let bridge = makeBridge()
        var recording = HAPService.switch(startIID: 0)
        recording.linked = [1]
        let aid = await bridge.addAccessory(
            info: AccessoryInfo(name: "Cam", manufacturer: "m", model: "m", serialNumber: "s", firmwareRevision: "1"),
            services: [recording, .switch(startIID: 0)]
        )
        let services = await bridge.accessoryDatabase().first { $0.aid == aid }!.services
        #expect(services[1].linked == [services[2].iid])
        #expect(services[2].linked.isEmpty)
    }

    @Test("write-response handler answers with a value and the writing connection")
    func writeResponse() async throws {
        let bridge = makeBridge()
        let aid = await bridge.addAccessory(
            info: AccessoryInfo(name: "Cam", manufacturer: "m", model: "m", serialNumber: "s", firmwareRevision: "1"),
            services: [HAPService(type: .dataStreamTransportManagement, characteristics: [
                HAPCharacteristic(iid: 0, type: .setupDataStreamTransport, value: .tlv8(Data()),
                                  permissions: [.read, .write, .writeResponse], format: .tlv8),
            ])]
        )
        let iid = await bridge.accessoryDatabase().first { $0.aid == aid }!.services[1].characteristics[0].iid
        await bridge.registerWriteResponseHandler(aid: aid, iid: iid) { _, connectionID in .tlv8(Data([UInt8(connectionID)])) }
        let response = try await bridge.writeCharacteristic(aid: aid, iid: iid, value: .tlv8(Data([1])), connectionID: 7)
        #expect(response == .tlv8(Data([7])))
    }
}

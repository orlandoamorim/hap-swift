// DataStreamTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
import HAPCrypto
@testable import HAPTransport

@Suite("HomeKit Data Stream Tests")
struct DataStreamTests {

    @Test("small values use one-byte tags")
    func smallTags() {
        #expect(DataStreamCodec.encode(.bool(true)) == Data([0x01]))
        #expect(DataStreamCodec.encode(.int(-1)) == Data([0x07]))
        #expect(DataStreamCodec.encode(.int(5)) == Data([0x0D]))
        #expect(DataStreamCodec.encode(.int(100)) == Data([0x30, 100]))
        #expect(DataStreamCodec.encode(.int(1000)) == Data([0x31, 0xE8, 0x03]))
        #expect(DataStreamCodec.encode(.string("id")) == Data([0x42, 0x69, 0x64]))
        #expect(DataStreamCodec.encode(.data(Data([1, 2]))) == Data([0x72, 1, 2]))
    }

    @Test("values round-trip, including long data and nested dictionaries")
    func roundTrip() throws {
        let value: HDSValue = .dictionary([
            "streamId": .int(1),
            "negative": .int(-70000),
            "big": .int(1 << 40),
            "ratio": .float(0.5),
            "packets": .array([.dictionary([
                "data": .data(Data(repeating: 7, count: 70000)),
                "metadata": .dictionary(["dataType": .string("mediaFragment"), "isLastDataChunk": .bool(false)]),
            ])]),
            "long": .array((0 ..< 20).map { .int(Int64($0)) }),
            "nothing": .null,
        ])
        #expect(try DataStreamCodec.decode(DataStreamCodec.encode(value)) == value)
    }

    @Test("compression tags refer back to earlier values")
    func compression() throws {
        // ["abc", <ref 0>]
        let data = Data([0xD2, 0x43, 0x61, 0x62, 0x63, 0xA0])
        #expect(try DataStreamCodec.decode(data) == .array([.string("abc"), .string("abc")]))
    }

    @Test("terminated dictionaries decode")
    func terminatedDictionary() throws {
        let data = Data([0xEF, 0x41, 0x61, 0x09, 0x03])
        #expect(try DataStreamCodec.decode(data) == .dictionary(["a": .int(1)]))
    }

    @Test("messages carry header and body")
    func message() throws {
        let hello = DataStreamMessage(protocol: "control", topic: "hello", kind: .request(id: 3))
        let decoded = try DataStreamMessage(decoding: hello.encoded())
        #expect(decoded == hello)

        let response = DataStreamMessage(protocol: "dataSend", topic: "open", kind: .response(id: 4, status: 0),
                                         message: .dictionary(["status": .int(0)]))
        #expect(try DataStreamMessage(decoding: response.encoded()) == response)
    }

    @Test("frames seal for the controller and open from it")
    func frames() throws {
        let keys = DataStreamKeys(sharedSecret: Data(repeating: 1, count: 32),
                                  controllerKeySalt: Data(repeating: 2, count: 32),
                                  accessoryKeySalt: Data(repeating: 3, count: 32))
        var accessory = DataStreamCipher(keys: keys)
        let frame = try accessory.seal(Data("hello".utf8))
        #expect(frame.prefix(4) == Data([0x01, 0, 0, 5]))
        #expect(DataStreamCipher.frameLength(in: frame) == frame.count)

        // The controller's frames use the other key: build one by hand and open it.
        let header = Data([0x01, 0, 0, 2])
        let sealed = try HAPEncryption.encrypt(plaintext: Data([9, 9]), key: keys.controllerToAccessory,
                                               nonce: HAPEncryption.buildNonce(counter: 0), aad: header)
        #expect(try accessory.open(header + sealed) == Data([9, 9]))
        #expect(throws: (any Error).self) { try accessory.open(header + sealed) }  // nonce 1 now
    }
}

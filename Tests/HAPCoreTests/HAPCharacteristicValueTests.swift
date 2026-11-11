// HAPCharacteristicValueTests.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Testing
@testable import HAPCore

@Suite("HAPCharacteristicValue Tests")
struct HAPCharacteristicValueTests {

    @Test("format mapping for each case")
    func formatMapping() {
        #expect(HAPCharacteristicValue.bool(true).format == .bool)
        #expect(HAPCharacteristicValue.uint8(0).format == .uint8)
        #expect(HAPCharacteristicValue.uint16(0).format == .uint16)
        #expect(HAPCharacteristicValue.uint32(0).format == .uint32)
        #expect(HAPCharacteristicValue.int32(0).format == .int)
        #expect(HAPCharacteristicValue.float(0.0).format == .float)
        #expect(HAPCharacteristicValue.string("").format == .string)
        #expect(HAPCharacteristicValue.data(Data()).format == .data)
        #expect(HAPCharacteristicValue.tlv8(Data()).format == .tlv8)
    }

    @Test("equality")
    func equality() {
        #expect(HAPCharacteristicValue.uint8(3) == HAPCharacteristicValue.uint8(3))
        #expect(HAPCharacteristicValue.uint8(3) != HAPCharacteristicValue.uint8(4))
        #expect(HAPCharacteristicValue.string("a") != HAPCharacteristicValue.uint8(0))
    }

    @Test("converts bool and numeric values to the characteristic's format")
    func conversion() {
        #expect(HAPCharacteristicValue.uint8(1).converted(to: .bool) == .bool(true))
        #expect(HAPCharacteristicValue.uint8(0).converted(to: .bool) == .bool(false))
        #expect(HAPCharacteristicValue.bool(true).converted(to: .uint8) == .uint8(1))
        #expect(HAPCharacteristicValue.uint8(24).converted(to: .float) == .float(24))
        #expect(HAPCharacteristicValue.uint8(44).converted(to: .uint16) == .uint16(44))
        #expect(HAPCharacteristicValue.uint8(5).converted(to: .uint8) == .uint8(5))
        #expect(HAPCharacteristicValue.float(1.5).converted(to: .uint8) == .float(1.5))
        #expect(HAPCharacteristicValue.string("x").converted(to: .bool) == .string("x"))
        #expect(HAPCharacteristicValue.tlv8(Data([1])).converted(to: .tlv8) == .tlv8(Data([1])))
    }
}

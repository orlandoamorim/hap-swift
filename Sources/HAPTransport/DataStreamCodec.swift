// DataStreamCodec.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

// MARK: - HDSValue

/// A value in the HomeKit Data Stream's binary format (Apple's OPACK), used for
/// the header and message of every HDS frame.
public indirect enum HDSValue: Sendable, Equatable {
    case bool(Bool)
    case null
    case int(Int64)
    case float(Double)
    case string(String)
    case data(Data)
    case array([HDSValue])
    case dictionary([String: HDSValue])

    public subscript(key: String) -> HDSValue? {
        if case .dictionary(let dict) = self { return dict[key] }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

public enum HDSCodecError: Error, Sendable {
    case truncated
    case unknownTag(UInt8)
    case invalidKey
    case invalidString
}

// MARK: - Encoding

public enum DataStreamCodec {

    public static func encode(_ value: HDSValue) -> Data {
        var out = Data()
        write(value, to: &out)
        return out
    }

    private static func write(_ value: HDSValue, to out: inout Data) {
        switch value {
        case .bool(let v):
            out.append(v ? 0x01 : 0x02)
        case .null:
            out.append(0x04)
        case .int(let v):
            switch v {
            case -1: out.append(0x07)
            case 0 ... 38: out.append(0x08 + UInt8(v))
            case Int64(Int8.min) ... Int64(Int8.max): out.append(0x30); appendLE(Int8(v), to: &out)
            case Int64(Int16.min) ... Int64(Int16.max): out.append(0x31); appendLE(Int16(v), to: &out)
            case Int64(Int32.min) ... Int64(Int32.max): out.append(0x32); appendLE(Int32(v), to: &out)
            default: out.append(0x33); appendLE(v, to: &out)
            }
        case .float(let v):
            out.append(0x36)
            appendLE(v.bitPattern, to: &out)
        case .string(let v):
            let bytes = Data(v.utf8)
            writeLength(bytes.count, short: 0x40, tag8: 0x61, to: &out)
            out.append(bytes)
        case .data(let v):
            writeLength(v.count, short: 0x70, tag8: 0x91, to: &out)
            out.append(v)
        case .array(let items):
            if items.count <= 14 {
                out.append(0xD0 + UInt8(items.count))
                items.forEach { write($0, to: &out) }
            } else {
                out.append(0xDF)
                items.forEach { write($0, to: &out) }
                out.append(0x03)
            }
        case .dictionary(let dict):
            let pairs = dict.sorted { $0.key < $1.key }
            if pairs.count <= 14 {
                out.append(0xE0 + UInt8(pairs.count))
            } else {
                out.append(0xEF)
            }
            for (key, value) in pairs {
                write(.string(key), to: &out)
                write(value, to: &out)
            }
            if pairs.count > 14 { out.append(0x03) }
        }
    }

    /// Lengths up to 32 go in the tag; longer ones use the 8/16/32-bit forms after `tag8`.
    private static func writeLength(_ count: Int, short: UInt8, tag8: UInt8, to out: inout Data) {
        switch count {
        case 0 ... 32: out.append(short + UInt8(count))
        case 33 ... 0xFF: out.append(tag8); out.append(UInt8(count))
        case 0x100 ... 0xFFFF: out.append(tag8 + 1); appendLE(UInt16(count), to: &out)
        default: out.append(tag8 + 2); appendLE(UInt32(count), to: &out)
        }
    }

    private static func appendLE<T: FixedWidthInteger>(_ v: T, to out: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> HDSValue {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.read()
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        /// Values a later compression tag (0xA0–0xCF) can refer back to.
        var tracked: [HDSValue] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset + n <= bytes.count else { throw HDSCodecError.truncated }
            defer { offset += n }
            return Array(bytes[offset ..< offset + n])
        }

        mutating func uint(_ n: Int) throws -> UInt64 {
            try take(n).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }

        mutating func sint(_ n: Int) throws -> Int64 {
            let raw = try uint(n)
            let shift = UInt64(64 - 8 * n)
            return Int64(bitPattern: raw << shift) >> Int64(shift)
        }

        mutating func peek() throws -> UInt8 {
            guard offset < bytes.count else { throw HDSCodecError.truncated }
            return bytes[offset]
        }

        mutating func read() throws -> HDSValue {
            let tag = try take(1)[0]
            switch tag {
            case 0x01: return .bool(true)
            case 0x02: return .bool(false)
            case 0x04: return .null
            case 0x05: return track(.data(Data(try take(16))))
            case 0x06: return track(.float(Double(bitPattern: try uint(8))))
            case 0x07: return .int(-1)
            case 0x08 ... 0x2F: return .int(Int64(tag - 0x08))
            case 0x30: return track(.int(try sint(1)))
            case 0x31: return track(.int(try sint(2)))
            case 0x32: return track(.int(try sint(4)))
            case 0x33: return track(.int(try sint(8)))
            case 0x35: return track(.float(Double(Float(bitPattern: UInt32(try uint(4))))))
            case 0x36: return track(.float(Double(bitPattern: try uint(8))))
            case 0x40 ... 0x60: return track(try string(Int(tag - 0x40)))
            case 0x61 ... 0x64: return track(try string(Int(try uint(1 << Int(tag - 0x61)))))
            case 0x6F:
                guard let end = bytes[offset...].firstIndex(of: 0) else { throw HDSCodecError.truncated }
                let value = try string(end - offset)
                offset += 1
                return track(value)
            case 0x70 ... 0x90: return track(.data(Data(try take(Int(tag - 0x70)))))
            case 0x91 ... 0x94: return track(.data(Data(try take(Int(try uint(1 << Int(tag - 0x91)))))))
            case 0x9F:
                var data = Data()
                while try peek() != 0x03 {
                    guard case .data(let chunk) = try read() else { throw HDSCodecError.unknownTag(tag) }
                    data.append(chunk)
                }
                offset += 1
                return .data(data)
            case 0xA0 ... 0xCF:
                let index = Int(tag - 0xA0)
                guard tracked.indices.contains(index) else { throw HDSCodecError.unknownTag(tag) }
                return tracked[index]
            case 0xD0 ... 0xDE:
                return .array(try (0 ..< Int(tag - 0xD0)).map { _ in try read() })
            case 0xDF:
                var items: [HDSValue] = []
                while try peek() != 0x03 { items.append(try read()) }
                offset += 1
                return .array(items)
            case 0xE0 ... 0xEE:
                var dict: [String: HDSValue] = [:]
                for _ in 0 ..< Int(tag - 0xE0) { try readPair(into: &dict) }
                return .dictionary(dict)
            case 0xEF:
                var dict: [String: HDSValue] = [:]
                while try peek() != 0x03 { try readPair(into: &dict) }
                offset += 1
                return .dictionary(dict)
            default:
                throw HDSCodecError.unknownTag(tag)
            }
        }

        mutating func readPair(into dict: inout [String: HDSValue]) throws {
            guard case .string(let key) = try read() else { throw HDSCodecError.invalidKey }
            dict[key] = try read()
        }

        mutating func string(_ count: Int) throws -> HDSValue {
            guard let s = String(bytes: try take(count), encoding: .utf8) else { throw HDSCodecError.invalidString }
            return .string(s)
        }

        mutating func track(_ value: HDSValue) -> HDSValue {
            if !tracked.contains(value) { tracked.append(value) }
            return value
        }
    }
}

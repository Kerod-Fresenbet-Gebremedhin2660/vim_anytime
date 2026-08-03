import Foundation

public indirect enum MessagePackValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([(MessagePackValue, MessagePackValue)])
    case `extension`(type: Int8, data: Data)

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .uint(let value) where value <= UInt64(Int64.max): return Int64(value)
        default: return nil
        }
    }

    public var arrayValue: [MessagePackValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> MessagePackValue? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { entry in
            entry.0.stringValue == key
        }?.1
    }

    public static func == (lhs: MessagePackValue, rhs: MessagePackValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.int(let lhs), .int(let rhs)): return lhs == rhs
        case (.uint(let lhs), .uint(let rhs)): return lhs == rhs
        case (.int(let lhs), .uint(let rhs)) where lhs >= 0: return UInt64(lhs) == rhs
        case (.uint(let lhs), .int(let rhs)) where rhs >= 0: return lhs == UInt64(rhs)
        case (.float(let lhs), .float(let rhs)): return lhs == rhs
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.binary(let lhs), .binary(let rhs)): return lhs == rhs
        case (.array(let lhs), .array(let rhs)): return lhs == rhs
        case (.map(let lhs), .map(let rhs)):
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { left, right in
                left.0 == right.0 && left.1 == right.1
            }
        case (.extension(let lhsType, let lhsData), .extension(let rhsType, let rhsData)):
            return lhsType == rhsType && lhsData == rhsData
        default:
            return false
        }
    }
}

public enum MessagePackCodingError: Error, Equatable, LocalizedError {
    case needMoreData
    case invalidMarker(UInt8)
    case invalidUTF8
    case collectionTooLarge(UInt64)

    public var errorDescription: String? {
        switch self {
        case .needMoreData: return "The MessagePack frame is incomplete."
        case .invalidMarker(let marker): return String(format: "Unsupported MessagePack marker 0x%02x.", marker)
        case .invalidUTF8: return "A MessagePack string was not valid UTF-8."
        case .collectionTooLarge(let size): return "MessagePack collection size \(size) exceeds the safety limit."
        }
    }
}

public enum MessagePackEncoder {
    public static func encode(_ value: MessagePackValue) -> Data {
        var data = Data()
        append(value, to: &data)
        return data
    }

    private static func append(_ value: MessagePackValue, to data: inout Data) {
        switch value {
        case .null:
            data.append(0xc0)
        case .bool(false):
            data.append(0xc2)
        case .bool(true):
            data.append(0xc3)
        case .int(let value):
            appendSigned(value, to: &data)
        case .uint(let value):
            appendUnsigned(value, to: &data)
        case .float(let value):
            data.append(0xcb)
            appendInteger(value.bitPattern, byteCount: 8, to: &data)
        case .string(let value):
            let bytes = Data(value.utf8)
            appendStringHeader(length: bytes.count, to: &data)
            data.append(bytes)
        case .binary(let bytes):
            appendBinaryHeader(length: bytes.count, to: &data)
            data.append(bytes)
        case .array(let values):
            appendArrayHeader(length: values.count, to: &data)
            for item in values { append(item, to: &data) }
        case .map(let entries):
            appendMapHeader(length: entries.count, to: &data)
            for (key, item) in entries {
                append(key, to: &data)
                append(item, to: &data)
            }
        case .extension(let type, let bytes):
            appendExtensionHeader(length: bytes.count, to: &data)
            data.append(UInt8(bitPattern: type))
            data.append(bytes)
        }
    }

    private static func appendSigned(_ value: Int64, to data: inout Data) {
        if value >= 0 {
            appendUnsigned(UInt64(value), to: &data)
        } else if value >= -32 {
            data.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int8.min) {
            data.append(0xd0)
            appendInteger(UInt64(UInt8(bitPattern: Int8(value))), byteCount: 1, to: &data)
        } else if value >= Int64(Int16.min) {
            data.append(0xd1)
            appendInteger(UInt64(UInt16(bitPattern: Int16(value))), byteCount: 2, to: &data)
        } else if value >= Int64(Int32.min) {
            data.append(0xd2)
            appendInteger(UInt64(UInt32(bitPattern: Int32(value))), byteCount: 4, to: &data)
        } else {
            data.append(0xd3)
            appendInteger(UInt64(bitPattern: value), byteCount: 8, to: &data)
        }
    }

    private static func appendUnsigned(_ value: UInt64, to data: inout Data) {
        if value <= 0x7f {
            data.append(UInt8(value))
        } else if value <= UInt64(UInt8.max) {
            data.append(0xcc)
            appendInteger(value, byteCount: 1, to: &data)
        } else if value <= UInt64(UInt16.max) {
            data.append(0xcd)
            appendInteger(value, byteCount: 2, to: &data)
        } else if value <= UInt64(UInt32.max) {
            data.append(0xce)
            appendInteger(value, byteCount: 4, to: &data)
        } else {
            data.append(0xcf)
            appendInteger(value, byteCount: 8, to: &data)
        }
    }

    private static func appendStringHeader(length: Int, to data: inout Data) {
        if length <= 31 {
            data.append(0xa0 | UInt8(length))
        } else if length <= Int(UInt8.max) {
            data.append(contentsOf: [0xd9, UInt8(length)])
        } else if length <= Int(UInt16.max) {
            data.append(0xda)
            appendInteger(UInt64(length), byteCount: 2, to: &data)
        } else {
            data.append(0xdb)
            appendInteger(UInt64(length), byteCount: 4, to: &data)
        }
    }

    private static func appendBinaryHeader(length: Int, to data: inout Data) {
        if length <= Int(UInt8.max) {
            data.append(contentsOf: [0xc4, UInt8(length)])
        } else if length <= Int(UInt16.max) {
            data.append(0xc5)
            appendInteger(UInt64(length), byteCount: 2, to: &data)
        } else {
            data.append(0xc6)
            appendInteger(UInt64(length), byteCount: 4, to: &data)
        }
    }

    private static func appendArrayHeader(length: Int, to data: inout Data) {
        if length <= 15 {
            data.append(0x90 | UInt8(length))
        } else if length <= Int(UInt16.max) {
            data.append(0xdc)
            appendInteger(UInt64(length), byteCount: 2, to: &data)
        } else {
            data.append(0xdd)
            appendInteger(UInt64(length), byteCount: 4, to: &data)
        }
    }

    private static func appendMapHeader(length: Int, to data: inout Data) {
        if length <= 15 {
            data.append(0x80 | UInt8(length))
        } else if length <= Int(UInt16.max) {
            data.append(0xde)
            appendInteger(UInt64(length), byteCount: 2, to: &data)
        } else {
            data.append(0xdf)
            appendInteger(UInt64(length), byteCount: 4, to: &data)
        }
    }

    private static func appendExtensionHeader(length: Int, to data: inout Data) {
        switch length {
        case 1: data.append(0xd4)
        case 2: data.append(0xd5)
        case 4: data.append(0xd6)
        case 8: data.append(0xd7)
        case 16: data.append(0xd8)
        case ...Int(UInt8.max):
            data.append(contentsOf: [0xc7, UInt8(length)])
        case ...Int(UInt16.max):
            data.append(0xc8)
            appendInteger(UInt64(length), byteCount: 2, to: &data)
        default:
            data.append(0xc9)
            appendInteger(UInt64(length), byteCount: 4, to: &data)
        }
    }

    private static func appendInteger(_ value: UInt64, byteCount: Int, to data: inout Data) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

public enum MessagePackDecoder {
    /// Decodes one value and returns its byte length. `needMoreData` is expected for a partial stream frame.
    public static func decodeOne(from data: Data) throws -> (value: MessagePackValue, consumed: Int) {
        var offset = 0
        let value = try decode(from: data, offset: &offset)
        return (value, offset)
    }

    private static let maximumCollectionSize: UInt64 = 64 * 1_024 * 1_024

    private static func decode(from data: Data, offset: inout Int) throws -> MessagePackValue {
        let marker = try readByte(from: data, offset: &offset)

        if marker <= 0x7f { return .uint(UInt64(marker)) }
        if marker >= 0xe0 { return .int(Int64(Int8(bitPattern: marker))) }
        if marker & 0xe0 == 0xa0 {
            return try decodeString(length: UInt64(marker & 0x1f), from: data, offset: &offset)
        }
        if marker & 0xf0 == 0x90 {
            return try decodeArray(length: UInt64(marker & 0x0f), from: data, offset: &offset)
        }
        if marker & 0xf0 == 0x80 {
            return try decodeMap(length: UInt64(marker & 0x0f), from: data, offset: &offset)
        }

        switch marker {
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: return try decodeBinary(length: try readUnsigned(1, from: data, offset: &offset), from: data, offset: &offset)
        case 0xc5: return try decodeBinary(length: try readUnsigned(2, from: data, offset: &offset), from: data, offset: &offset)
        case 0xc6: return try decodeBinary(length: try readUnsigned(4, from: data, offset: &offset), from: data, offset: &offset)
        case 0xc7: return try decodeExtension(length: try readUnsigned(1, from: data, offset: &offset), from: data, offset: &offset)
        case 0xc8: return try decodeExtension(length: try readUnsigned(2, from: data, offset: &offset), from: data, offset: &offset)
        case 0xc9: return try decodeExtension(length: try readUnsigned(4, from: data, offset: &offset), from: data, offset: &offset)
        case 0xca:
            let bits = UInt32(try readUnsigned(4, from: data, offset: &offset))
            return .float(Double(Float(bitPattern: bits)))
        case 0xcb:
            return .float(Double(bitPattern: try readUnsigned(8, from: data, offset: &offset)))
        case 0xcc: return .uint(try readUnsigned(1, from: data, offset: &offset))
        case 0xcd: return .uint(try readUnsigned(2, from: data, offset: &offset))
        case 0xce: return .uint(try readUnsigned(4, from: data, offset: &offset))
        case 0xcf: return .uint(try readUnsigned(8, from: data, offset: &offset))
        case 0xd0: return .int(Int64(Int8(bitPattern: UInt8(try readUnsigned(1, from: data, offset: &offset)))))
        case 0xd1: return .int(Int64(Int16(bitPattern: UInt16(try readUnsigned(2, from: data, offset: &offset)))))
        case 0xd2: return .int(Int64(Int32(bitPattern: UInt32(try readUnsigned(4, from: data, offset: &offset)))))
        case 0xd3: return .int(Int64(bitPattern: try readUnsigned(8, from: data, offset: &offset)))
        case 0xd4: return try decodeExtension(length: 1, from: data, offset: &offset)
        case 0xd5: return try decodeExtension(length: 2, from: data, offset: &offset)
        case 0xd6: return try decodeExtension(length: 4, from: data, offset: &offset)
        case 0xd7: return try decodeExtension(length: 8, from: data, offset: &offset)
        case 0xd8: return try decodeExtension(length: 16, from: data, offset: &offset)
        case 0xd9: return try decodeString(length: try readUnsigned(1, from: data, offset: &offset), from: data, offset: &offset)
        case 0xda: return try decodeString(length: try readUnsigned(2, from: data, offset: &offset), from: data, offset: &offset)
        case 0xdb: return try decodeString(length: try readUnsigned(4, from: data, offset: &offset), from: data, offset: &offset)
        case 0xdc: return try decodeArray(length: try readUnsigned(2, from: data, offset: &offset), from: data, offset: &offset)
        case 0xdd: return try decodeArray(length: try readUnsigned(4, from: data, offset: &offset), from: data, offset: &offset)
        case 0xde: return try decodeMap(length: try readUnsigned(2, from: data, offset: &offset), from: data, offset: &offset)
        case 0xdf: return try decodeMap(length: try readUnsigned(4, from: data, offset: &offset), from: data, offset: &offset)
        default: throw MessagePackCodingError.invalidMarker(marker)
        }
    }

    private static func decodeString(length: UInt64, from data: Data, offset: inout Int) throws -> MessagePackValue {
        let bytes = try readData(length: length, from: data, offset: &offset)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw MessagePackCodingError.invalidUTF8
        }
        return .string(string)
    }

    private static func decodeBinary(length: UInt64, from data: Data, offset: inout Int) throws -> MessagePackValue {
        .binary(try readData(length: length, from: data, offset: &offset))
    }

    private static func decodeExtension(length: UInt64, from data: Data, offset: inout Int) throws -> MessagePackValue {
        let type = Int8(bitPattern: try readByte(from: data, offset: &offset))
        return .extension(type: type, data: try readData(length: length, from: data, offset: &offset))
    }

    private static func decodeArray(length: UInt64, from data: Data, offset: inout Int) throws -> MessagePackValue {
        let count = try checkedCount(length)
        var values: [MessagePackValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try decode(from: data, offset: &offset)) }
        return .array(values)
    }

    private static func decodeMap(length: UInt64, from data: Data, offset: inout Int) throws -> MessagePackValue {
        let count = try checkedCount(length)
        var values: [(MessagePackValue, MessagePackValue)] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append((try decode(from: data, offset: &offset), try decode(from: data, offset: &offset)))
        }
        return .map(values)
    }

    private static func checkedCount(_ value: UInt64) throws -> Int {
        guard value <= maximumCollectionSize, value <= UInt64(Int.max) else {
            throw MessagePackCodingError.collectionTooLarge(value)
        }
        return Int(value)
    }

    private static func readByte(from data: Data, offset: inout Int) throws -> UInt8 {
        guard offset < data.count else { throw MessagePackCodingError.needMoreData }
        defer { offset += 1 }
        let index = data.index(data.startIndex, offsetBy: offset)
        return data[index]
    }

    private static func readUnsigned(_ byteCount: Int, from data: Data, offset: inout Int) throws -> UInt64 {
        guard byteCount >= 0, data.count - offset >= byteCount else {
            throw MessagePackCodingError.needMoreData
        }
        var value: UInt64 = 0
        for _ in 0..<byteCount {
            let index = data.index(data.startIndex, offsetBy: offset)
            value = (value << 8) | UInt64(data[index])
            offset += 1
        }
        return value
    }

    private static func readData(length: UInt64, from data: Data, offset: inout Int) throws -> Data {
        let count = try checkedCount(length)
        guard data.count - offset >= count else { throw MessagePackCodingError.needMoreData }
        defer { offset += count }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        return data.subdata(in: start..<end)
    }
}

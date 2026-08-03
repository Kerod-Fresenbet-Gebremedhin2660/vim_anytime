import Foundation
import XCTest
@testable import VimAnyCore

final class MessagePackTests: XCTestCase {
    func testRoundTripsRPCValueShapes() throws {
        let value: MessagePackValue = .array([
            .int(0),
            .uint(UInt64.max),
            .string("héllo 😀"),
            .binary(Data([0, 1, 2, 255])),
            .map([
                (.string("true"), .bool(true)),
                (.string("nil"), .null),
            ]),
            .extension(type: 2, data: Data([9, 8, 7, 6])),
        ])
        let data = MessagePackEncoder.encode(value)
        let decoded = try MessagePackDecoder.decodeOne(from: data)
        XCTAssertEqual(decoded.value, value)
        XCTAssertEqual(decoded.consumed, data.count)
    }

    func testPartialFrameReportsNeedMoreData() {
        let data = MessagePackEncoder.encode(.string(String(repeating: "x", count: 400)))
        XCTAssertThrowsError(try MessagePackDecoder.decodeOne(from: Data(data.dropLast()))) { error in
            XCTAssertEqual(error as? MessagePackCodingError, .needMoreData)
        }
    }

    func testDecodesConcatenatedFramesOneAtATime() throws {
        var stream = MessagePackEncoder.encode(.string("first"))
        stream.append(MessagePackEncoder.encode(.int(-42)))
        let first = try MessagePackDecoder.decodeOne(from: stream)
        XCTAssertEqual(first.value, .string("first"))
        let remaining = stream.dropFirst(first.consumed)
        let second = try MessagePackDecoder.decodeOne(from: Data(remaining))
        XCTAssertEqual(second.value, .int(-42))
    }

    func testDecoderSupportsDataWhoseStartIndexWasAdvanced() throws {
        var stream = MessagePackEncoder.encode(.string(String(repeating: "metadata", count: 100)))
        stream.append(MessagePackEncoder.encode(.array([.int(1), .int(2), .null, .int(1)])))
        let first = try MessagePackDecoder.decodeOne(from: stream)
        stream.removeFirst(first.consumed)

        let second = try MessagePackDecoder.decodeOne(from: stream)
        XCTAssertEqual(second.value, .array([.int(1), .int(2), .null, .int(1)]))
        XCTAssertEqual(second.consumed, stream.count)
    }
}

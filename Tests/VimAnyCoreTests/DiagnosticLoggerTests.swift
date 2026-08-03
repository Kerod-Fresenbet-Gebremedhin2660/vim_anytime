import Foundation
import XCTest
@testable import VimAnyCore

final class DiagnosticLoggerTests: XCTestCase {
    func testLoggerAppendsThreadSafeSingleLineEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimAnyLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("VimAny.log")
        let logger = DiagnosticLogger(fileURL: fileURL)
        logger.info("Test", "first line\nsecond line")

        DispatchQueue.concurrentPerform(iterations: 50) { index in
            logger.debug("Concurrent", "entry=\(index)")
        }
        logger.flush()

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[INFO] [Session] start"))
        XCTAssertTrue(contents.contains("[INFO] [Test] first line\\nsecond line"))
        XCTAssertFalse(contents.contains("first line\nsecond line"))
        XCTAssertEqual(
            contents.components(separatedBy: "\n").filter { $0.contains("[DEBUG] [Concurrent]") }.count,
            50
        )
    }
}

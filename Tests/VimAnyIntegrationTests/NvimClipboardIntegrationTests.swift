import AppKit
import XCTest
@testable import VimAnyCore

@MainActor
final class NvimClipboardIntegrationTests: XCTestCase {
    func testYYAndYankToEndUseMacOSClipboard() async throws {
        try await withClipboardHost { host, clipboard in
            try await host.load(
                text: "α first\nβ second",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("yy"))
            _ = try await host.snapshot()
            XCTAssertEqual(clipboard.readText(), "α first\n")

            try await host.load(
                text: "one two",
                selection: .caret(at: .init(line: 0, utf8Column: 4))
            )
            try await host.sendKey(VimKey("y$"))
            _ = try await host.snapshot()
            XCTAssertEqual(clipboard.readText(), "two")
        }
    }

    func testVisualYankUsesMacOSClipboard() async throws {
        try await withClipboardHost { host, clipboard in
            try await host.load(
                text: "abcdef",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("vlly"))
            _ = try await host.snapshot()
            XCTAssertEqual(clipboard.readText(), "abc")
        }
    }

    func testPAndUppercasePReadCurrentMacOSClipboard() async throws {
        try await withClipboardHost { host, clipboard in
            clipboard.writeTextIntentionally("😀")
            try await host.load(
                text: "ab",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("p"))
            var snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "a😀b")

            clipboard.writeTextIntentionally("二")
            try await host.load(
                text: "ab",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("P"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "二ab")
        }
    }

    func testUnicodeMultilineClipboardPastesLinewise() async throws {
        try await withClipboardHost { host, clipboard in
            clipboard.writeTextIntentionally("α😀\n二\n")
            try await host.load(
                text: "one\ntwo",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("p"))
            let snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "one\nα😀\n二\ntwo")
        }
    }
}

@MainActor
private func withClipboardHost(
    _ body: (NvimHost, SystemClipboardService) async throws -> Void
) async throws {
    let pasteboard = NSPasteboard(name: .init("dev.vimany.clipboard-tests.\(UUID().uuidString)"))
    let clipboard = SystemClipboardService(pasteboard: pasteboard)
    let host = NvimHost(clipboard: clipboard)
    do {
        try await host.start()
    } catch NvimHostError.executableNotFound {
        throw XCTSkip("Neovim is not installed")
    }
    do {
        try await body(host, clipboard)
        await host.stop()
    } catch {
        await host.stop()
        throw error
    }
}

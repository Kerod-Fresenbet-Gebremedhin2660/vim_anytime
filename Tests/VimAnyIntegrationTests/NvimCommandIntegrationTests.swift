import AppKit
import XCTest
@testable import VimAnyCore

@MainActor
final class NvimCommandIntegrationTests: XCTestCase {
    func testRepresentativeMotionsAndCounts() async throws {
        try await withHost { host, _ in
            let text = "one two three\n  four five\nsix"
            let cases: [(name: String, start: TextPosition, keys: String, expected: TextPosition)] = [
                ("h", TextPosition(line: 0, utf8Column: 1), "h", TextPosition(line: 0, utf8Column: 0)),
                ("j", TextPosition(line: 0, utf8Column: 0), "j", TextPosition(line: 1, utf8Column: 0)),
                ("k", TextPosition(line: 1, utf8Column: 0), "k", TextPosition(line: 0, utf8Column: 0)),
                ("l", TextPosition(line: 0, utf8Column: 0), "l", TextPosition(line: 0, utf8Column: 1)),
                ("w", TextPosition(line: 0, utf8Column: 0), "w", TextPosition(line: 0, utf8Column: 4)),
                ("b", TextPosition(line: 0, utf8Column: 4), "b", TextPosition(line: 0, utf8Column: 0)),
                ("e", TextPosition(line: 0, utf8Column: 0), "e", TextPosition(line: 0, utf8Column: 2)),
                ("ge", TextPosition(line: 0, utf8Column: 4), "ge", TextPosition(line: 0, utf8Column: 2)),
                ("0", TextPosition(line: 0, utf8Column: 7), "0", TextPosition(line: 0, utf8Column: 0)),
                ("^", TextPosition(line: 1, utf8Column: 7), "^", TextPosition(line: 1, utf8Column: 2)),
                ("$", TextPosition(line: 0, utf8Column: 0), "$", TextPosition(line: 0, utf8Column: 12)),
                ("gg", TextPosition(line: 2, utf8Column: 0), "gg", TextPosition(line: 0, utf8Column: 0)),
                ("G", TextPosition(line: 0, utf8Column: 0), "G", TextPosition(line: 2, utf8Column: 0)),
                ("3w", TextPosition(line: 0, utf8Column: 0), "3w", TextPosition(line: 1, utf8Column: 2)),
            ]

            for testCase in cases {
                let snapshot = try await edit(
                    host,
                    text: text,
                    cursor: testCase.start,
                    keys: testCase.keys
                )
                XCTAssertEqual(snapshot.cursor, testCase.expected, testCase.name)
                XCTAssertEqual(snapshot.text, text, testCase.name)
            }
        }
    }

    func testRepresentativeOperatorsTextObjectsAndLineCommands() async throws {
        try await withHost { host, _ in
            let cases: [(name: String, text: String, cursor: TextPosition, keys: String, expected: String)] = [
                ("dw", "one two three", .init(line: 0, utf8Column: 0), "dw", "two three"),
                ("d2w", "one two three", .init(line: 0, utf8Column: 0), "d2w", "three"),
                ("2d3w", "one two three four five six seven", .init(line: 0, utf8Column: 0), "2d3w", "seven"),
                ("ciw", "one two", .init(line: 0, utf8Column: 1), "ciwX<Esc>", "X two"),
                ("di quote", "say \"hello world\" now", .init(line: 0, utf8Column: 7), "di\"", "say \"\" now"),
                ("da paren", "before (inside words) after", .init(line: 0, utf8Column: 10), "da(", "before  after"),
                ("dd", "one\ntwo\nthree", .init(line: 0, utf8Column: 0), "dd", "two\nthree"),
                ("D", "one two", .init(line: 0, utf8Column: 4), "D", "one "),
                ("cc", "one\ntwo", .init(line: 0, utf8Column: 0), "ccX<Esc>", "X\ntwo"),
                ("C", "one two", .init(line: 0, utf8Column: 4), "CX<Esc>", "one X"),
                ("x", "abc", .init(line: 0, utf8Column: 0), "x", "bc"),
            ]

            for testCase in cases {
                let snapshot = try await edit(
                    host,
                    text: testCase.text,
                    cursor: testCase.cursor,
                    keys: testCase.keys
                )
                XCTAssertEqual(snapshot.text, testCase.expected, testCase.name)
            }
        }
    }

    func testUndoRedoDotRepeatAndVisualModes() async throws {
        try await withHost { host, _ in
            try await host.load(text: "abc", selection: .caret(at: .init(line: 0, utf8Column: 0)))
            try await host.sendKey(VimKey("x"))
            var snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "bc")
            try await host.sendKey(VimKey("u"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "abc")
            try await host.sendKey(VimKey("<C-r>"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "bc")

            let dot = try await edit(
                host,
                text: "abc",
                cursor: .init(line: 0, utf8Column: 0),
                keys: "x."
            )
            XCTAssertEqual(dot.text, "c")

            let visual = try await edit(
                host,
                text: "abcde",
                cursor: .init(line: 0, utf8Column: 0),
                keys: "vllx"
            )
            XCTAssertEqual(visual.text, "de")

            let visualLine = try await edit(
                host,
                text: "one\ntwo",
                cursor: .init(line: 0, utf8Column: 0),
                keys: "Vx"
            )
            XCTAssertEqual(visualLine.text, "two")
        }
    }

    func testSearchNextAndPrevious() async throws {
        try await withHost { host, _ in
            try await host.load(
                text: "hay needle hay needle",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("/needle<CR>"))
            var snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.cursor.utf8Column, 4)
            try await host.sendKey(VimKey("n"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.cursor.utf8Column, 15)
            try await host.sendKey(VimKey("N"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.cursor.utf8Column, 4)
        }
    }

    func testInsertReplaceAndUnicodeMultilineInput() async throws {
        try await withHost { host, _ in
            try await host.load(text: "abc", selection: .caret(at: .init(line: 0, utf8Column: 0)))
            try await host.sendKey(VimKey("i"))
            var snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.mode, .insert)
            try await host.insertText("😀\n二")
            try await host.sendKey(VimKey("<Esc>"))
            let inserted = try await host.snapshot()
            XCTAssertEqual(inserted.text, "😀\n二abc")
            XCTAssertEqual(inserted.mode, .normal)

            try await host.load(text: "abc", selection: .caret(at: .init(line: 0, utf8Column: 0)))
            try await host.sendKey(VimKey("R"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.mode, .replace)
            try await host.insertText("XY")
            try await host.sendKey(VimKey("<Esc>"))
            snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "XYc")
        }
    }

    func testUnexpectedNeovimExitRestartsAndRecoversLatestSnapshot() async throws {
        try await withHost { host, _ in
            try await host.load(
                text: "abc",
                selection: .caret(at: .init(line: 0, utf8Column: 0))
            )
            try await host.sendKey(VimKey("x"))
            let snapshot = try await host.snapshot()
            XCTAssertEqual(snapshot.text, "bc")

            await host.terminateEmbeddedProcessForTesting()
            try? await Task.sleep(nanoseconds: 80_000_000)
            try await host.sendKey(VimKey("x"))
            let recovered = try await host.snapshot()
            XCTAssertEqual(recovered.text, "c")
            let isRunning = await host.isProcessRunning()
            XCTAssertTrue(isRunning)
        }
    }

    private func edit(
        _ host: NvimHost,
        text: String,
        cursor: TextPosition,
        keys: String
    ) async throws -> EditorSnapshot {
        try await host.load(text: text, selection: .caret(at: cursor))
        try await host.sendKey(VimKey(keys))
        return try await host.snapshot()
    }
}

@MainActor
private func withHost(
    _ body: (NvimHost, SystemClipboardService) async throws -> Void
) async throws {
    let pasteboard = NSPasteboard(name: .init("dev.vimany.nvim-tests.\(UUID().uuidString)"))
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

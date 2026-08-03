import Foundation
import XCTest
@testable import VimAnyCore

@MainActor
final class EditorViewModelTests: XCTestCase {
    func testShellLikeExCommandIsRejectedWithoutReachingEngine() async throws {
        let engine = MockEditingEngine()
        let viewModel = EditorViewModel(engine: engine)
        var lastSnapshot: EditorSnapshot?
        viewModel.onSnapshot = { lastSnapshot = $0 }
        try await viewModel.load(
            text: "text",
            selection: .caret(at: TextPosition(line: 0, utf8Column: 0))
        )

        viewModel.handle(.beginExCommand)
        viewModel.handle(.appendExText("!open /tmp"))
        viewModel.handle(.submitExCommand)

        XCTAssertEqual(lastSnapshot?.message, "E492: Not an allowed VimAny command: !open /tmp")
        let commands = await engine.executedCommands()
        let keys = await engine.receivedKeys()
        XCTAssertEqual(commands, [])
        XCTAssertEqual(keys, [])
    }

    func testWhitelistedUndoReachesSafeEngineAPI() async throws {
        let engine = MockEditingEngine()
        let viewModel = EditorViewModel(engine: engine)
        try await viewModel.load(
            text: "text",
            selection: .caret(at: TextPosition(line: 0, utf8Column: 0))
        )

        viewModel.handle(.beginExCommand)
        viewModel.handle(.appendExText("undo"))
        viewModel.handle(.submitExCommand)
        _ = try await viewModel.snapshotForCommit()

        let commands = await engine.executedCommands()
        XCTAssertEqual(commands, [.undo])
    }

    func testWhitelistedWriteStaysAnApplicationCommand() async throws {
        let engine = MockEditingEngine()
        let viewModel = EditorViewModel(engine: engine)
        var applicationCommand: EditorApplicationCommand?
        viewModel.onApplicationCommand = { applicationCommand = $0 }
        try await viewModel.load(
            text: "text",
            selection: .caret(at: TextPosition(line: 0, utf8Column: 0))
        )

        viewModel.handle(.beginExCommand)
        viewModel.handle(.appendExText("w"))
        viewModel.handle(.submitExCommand)

        XCTAssertEqual(applicationCommand, .commit)
        let commands = await engine.executedCommands()
        XCTAssertEqual(commands, [])
    }
}

private actor MockEditingEngine: NvimEditingEngine {
    private var keys: [VimKey] = []
    private var commands: [SafeExCommand] = []
    private var current = EditorSnapshot(
        text: "",
        cursor: TextPosition(line: 0, utf8Column: 0),
        selection: nil,
        mode: .normal
    )

    func start() async throws {}

    func load(text: String, selection: EditorSelection) async throws {
        current = EditorSnapshot(
            text: text,
            cursor: selection.head,
            selection: selection.kind == .caret ? nil : selection,
            mode: .normal
        )
    }

    func sendKey(_ key: VimKey) async throws { keys.append(key) }
    func insertText(_ text: String) async throws {}
    func snapshot() async throws -> EditorSnapshot { current }
    func execute(_ command: SafeExCommand) async throws { commands.append(command) }
    func setNativeSelection(_ selection: EditorSelection) async throws {}
    func reset() async throws {}
    func stop() async {}

    func executedCommands() -> [SafeExCommand] { commands }
    func receivedKeys() -> [VimKey] { keys }
}

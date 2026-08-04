import AppKit
import Foundation
import XCTest
@testable import VimAnyCore

@MainActor
final class FieldCommitCoordinatorTests: XCTestCase {
    func testCancelDoesNotWriteAndRestoresOriginalApplicationFocus() throws {
        let accessibility = MockAccessibilityService()
        let fallback = MockFallbackWriter()
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        coordinator.cancel()

        XCTAssertEqual(accessibility.writeCalls, 0)
        XCTAssertEqual(fallback.calls, 0)
        XCTAssertEqual(accessibility.focusCalls, 1)
    }

    func testDirectCommitWritesSelectionAndRestoresFocus() async throws {
        let accessibility = MockAccessibilityService()
        let fallback = MockFallbackWriter()
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "edited 😀",
            selectionRange: NSRange(location: 7, length: 2),
            restoreFocus: true
        )

        XCTAssertEqual(result, .direct)
        XCTAssertEqual(accessibility.lastText, "edited 😀")
        XCTAssertEqual(accessibility.lastSelection, NSRange(location: 7, length: 2))
        XCTAssertEqual(accessibility.focusCalls, 1)
        XCTAssertEqual(fallback.calls, 0)
        XCTAssertEqual(clipboard.calls, 0)
    }

    func testRejectedAXWriteUsesClipboardFallbackAndFocusesTarget() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let fallback = MockFallbackWriter()
        fallback.onSuccessfulReplace = { accessibility.currentText = $0 }
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "fallback text",
            selectionRange: NSRange(location: 4, length: 0),
            restoreFocus: true
        )

        XCTAssertEqual(result, .clipboardFallback)
        XCTAssertEqual(fallback.calls, 1)
        XCTAssertEqual(fallback.lastText, "fallback text")
        XCTAssertEqual(accessibility.focusCalls, 1)
        XCTAssertEqual(accessibility.selectionWriteCalls, 1)
        XCTAssertEqual(clipboard.calls, 0)
    }

    func testPostedPasteThatDidNotChangeFieldCopiesTextForWriteAndQuit() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let fallback = MockFallbackWriter()
        fallback.result = true
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "target ignored paste",
            selectionRange: NSRange(location: 20, length: 0),
            restoreFocus: true,
            copyTextToClipboardOnFailure: true
        )

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(clipboard.lastText, "target ignored paste")
        XCTAssertEqual(accessibility.currentText, "original")
        XCTAssertEqual(accessibility.selectionWriteCalls, 0)
    }

    func testReportedDirectWriteWithoutValueChangeFallsThroughToVerifiedPaste() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeAppliesText = false
        let fallback = MockFallbackWriter()
        fallback.onSuccessfulReplace = { accessibility.currentText = $0 }
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "verified fallback",
            selectionRange: NSRange(location: 3, length: 0),
            restoreFocus: true
        )

        XCTAssertEqual(result, .clipboardFallback)
        XCTAssertEqual(fallback.calls, 1)
        XCTAssertEqual(accessibility.currentText, "verified fallback")
        XCTAssertEqual(clipboard.calls, 0)
    }

    func testWriteAndQuitCopiesEditedTextWhenEveryFieldWriteStrategyFails() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let fallback = MockFallbackWriter()
        fallback.result = false
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "unsaved 😀\nsecond line",
            selectionRange: NSRange(location: 8, length: 2),
            restoreFocus: true,
            copyTextToClipboardOnFailure: true
        )

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(clipboard.calls, 1)
        XCTAssertEqual(clipboard.lastText, "unsaved 😀\nsecond line")
        XCTAssertEqual(fallback.calls, 1)
        XCTAssertEqual(accessibility.selectionWriteCalls, 0)
    }

    func testWriteWithoutQuitKeepsFailureAndDoesNotOverwriteClipboard() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let fallback = MockFallbackWriter()
        fallback.result = false
        let clipboard = MockClipboardWriter()
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "still in panel",
            selectionRange: NSRange(location: 0, length: 0),
            restoreFocus: false,
            copyTextToClipboardOnFailure: false
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(clipboard.calls, 0)
    }

    func testFailedLastResortClipboardWriteKeepsCommitFailed() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let fallback = MockFallbackWriter()
        fallback.result = false
        let clipboard = MockClipboardWriter()
        clipboard.result = false
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "must remain visible",
            selectionRange: NSRange(location: 0, length: 0),
            restoreFocus: true,
            copyTextToClipboardOnFailure: true
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(clipboard.calls, 1)
    }

    func testLastResortCopyRunsAfterTemporaryClipboardRestoration() async throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.vimany.commit-tests.\(UUID().uuidString)")
        )
        let clipboard = SystemClipboardService(pasteboard: pasteboard)
        clipboard.writeTextIntentionally("previous intentional yank")
        let fallback = ClipboardFallbackService(
            clipboard: clipboard,
            pasteAction: { _ in false },
            restorationDelayNanoseconds: 0
        )
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let coordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        try coordinator.begin()

        let result = await coordinator.commit(
            text: "final edited 😀\ntext",
            selectionRange: NSRange(location: 0, length: 0),
            restoreFocus: true,
            copyTextToClipboardOnFailure: true
        )

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(clipboard.readText(), "final edited 😀\ntext")
    }
}

@MainActor
private final class MockAccessibilityService: AccessibilityTextServicing {
    let target = AccessibilityTextTarget(testProcessIdentifier: 123)
    var writeResult = true
    var writeCalls = 0
    var selectionWriteCalls = 0
    var focusCalls = 0
    var lastText: String?
    var lastSelection: NSRange?
    var currentText = "original"
    var writeAppliesText = true

    func captureFocusedTextField() throws -> CapturedTextField {
        CapturedTextField(
            text: "original",
            selectionRange: NSRange(location: 2, length: 0),
            target: target,
            applicationName: "Mock"
        )
    }

    func write(text: String, selectionRange: NSRange, to target: AccessibilityTextTarget) -> Bool {
        writeCalls += 1
        lastText = text
        lastSelection = selectionRange
        if writeResult, writeAppliesText { currentText = text }
        return writeResult
    }

    func readText(from target: AccessibilityTextTarget) -> String? {
        currentText
    }

    func writeSelection(_ selectionRange: NSRange, to target: AccessibilityTextTarget) {
        selectionWriteCalls += 1
        lastSelection = selectionRange
    }

    func restoreFocus(to target: AccessibilityTextTarget) {
        focusCalls += 1
    }
}

@MainActor
private final class MockFallbackWriter: ClipboardFallbackWriting {
    var result = true
    var calls = 0
    var lastText: String?
    var onSuccessfulReplace: ((String) -> Void)?

    func replace(
        text: String,
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool {
        calls += 1
        lastText = text
        focusTarget()
        if result { onSuccessfulReplace?(text) }
        return result
    }
}

@MainActor
private final class MockClipboardWriter: IntentionalClipboardWriting {
    var result = true
    var calls = 0
    var lastText: String?

    func writeTextIntentionally(_ text: String) -> Bool {
        calls += 1
        lastText = text
        return result
    }
}

import Foundation
import XCTest
@testable import VimAnyCore

@MainActor
final class FieldCommitCoordinatorTests: XCTestCase {
    func testCancelDoesNotWriteAndRestoresOriginalApplicationFocus() throws {
        let accessibility = MockAccessibilityService()
        let fallback = MockFallbackWriter()
        let coordinator = FieldCommitCoordinator(accessibility: accessibility, fallback: fallback)
        try coordinator.begin()

        coordinator.cancel()

        XCTAssertEqual(accessibility.writeCalls, 0)
        XCTAssertEqual(fallback.calls, 0)
        XCTAssertEqual(accessibility.focusCalls, 1)
    }

    func testDirectCommitWritesSelectionAndRestoresFocus() async throws {
        let accessibility = MockAccessibilityService()
        let fallback = MockFallbackWriter()
        let coordinator = FieldCommitCoordinator(accessibility: accessibility, fallback: fallback)
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
    }

    func testRejectedAXWriteUsesClipboardFallbackAndFocusesTarget() async throws {
        let accessibility = MockAccessibilityService()
        accessibility.writeResult = false
        let fallback = MockFallbackWriter()
        let coordinator = FieldCommitCoordinator(accessibility: accessibility, fallback: fallback)
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
        return writeResult
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

    func replace(
        text: String,
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool {
        calls += 1
        lastText = text
        focusTarget()
        return result
    }
}

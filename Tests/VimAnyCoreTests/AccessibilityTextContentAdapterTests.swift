import Foundation
import XCTest
@testable import VimAnyCore

final class AccessibilityTextContentAdapterTests: XCTestCase {
    private let fileIcon = "\u{E07D}"
    private let closeIcon = "\u{EA76}"
    private let filename = "ExchangeRateSwapCard.tsx"

    func testCursorReferenceDecorationsBecomeReadableAtFileText() {
        let rawText = "Before\n\(fileIcon)\n\(filename)\n\(closeIcon)\nAfter"
        let rawCloseRange = (rawText as NSString).range(of: closeIcon)

        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawText,
            selectionRange: NSRange(location: rawCloseRange.location, length: 0),
            applicationName: "Cursor"
        )

        XCTAssertEqual(adapter.editableText, "Before\n@\(filename)\nAfter")
        XCTAssertEqual(adapter.adaptedReferenceCount, 1)
        let tokenRange = (adapter.editableText as NSString).range(of: "@\(filename)")
        XCTAssertEqual(
            adapter.editableSelectionRange,
            NSRange(location: NSMaxRange(tokenRange), length: 0)
        )
        XCTAssertFalse(adapter.editableText.unicodeScalars.contains { scalar in
            (0xE000...0xF8FF).contains(scalar.value)
        })
    }

    func testDirectWriteRehydratesUnchangedReferenceAndMapsUnicodeSelection() {
        let rawReference = "\(fileIcon)\n\(filename)\n\(closeIcon)"
        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawReference,
            selectionRange: NSRange(location: 0, length: 0),
            applicationName: "Cursor"
        )
        let editedText = "Please inspect @\(filename) carefully 😀"
        let payload = adapter.directWritePayload(
            editableText: editedText,
            selectionRange: NSRange(location: editedText.utf16.count, length: 0)
        )

        XCTAssertEqual(payload.text, "Please inspect \(rawReference) carefully 😀")
        XCTAssertEqual(payload.selectionRange.location, payload.text.utf16.count)
        XCTAssertEqual(adapter.normalizeReadBack(payload.text), editedText)
    }

    func testEditedReferenceNameIsNotRehydratedAsOriginalChip() {
        let rawReference = "\(fileIcon)\n\(filename)\n\(closeIcon)"
        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawReference,
            selectionRange: NSRange(location: 0, length: 0),
            applicationName: "Cursor"
        )
        let renamedText = "@\(filename)Renamed"

        let payload = adapter.directWritePayload(
            editableText: renamedText,
            selectionRange: NSRange(location: renamedText.utf16.count, length: 0)
        )

        XCTAssertEqual(payload.text, renamedText)
        XCTAssertEqual(payload.selectionRange.location, renamedText.utf16.count)
    }

    func testMultipleInlineReferencesAreDecodedAndRehydratedAfterReordering() {
        let secondIcon = "\u{E755}"
        let secondFilename = "PricingEngine.swift"
        let firstRawReference = "\(fileIcon)\n\(filename)\n\(closeIcon)"
        let secondRawReference = "\(secondIcon)\n\(secondFilename)\n\(closeIcon)"
        let rawText = "Compare \(firstRawReference) with \(secondRawReference)."
        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawText,
            selectionRange: NSRange(location: rawText.utf16.count, length: 0),
            applicationName: "Cursor"
        )

        XCTAssertEqual(
            adapter.editableText,
            "Compare @\(filename) with @\(secondFilename)."
        )
        XCTAssertEqual(adapter.adaptedReferenceCount, 2)

        let reordered = "Compare @\(secondFilename) with @\(filename)."
        let payload = adapter.directWritePayload(
            editableText: reordered,
            selectionRange: NSRange(location: reordered.utf16.count, length: 0)
        )
        XCTAssertEqual(
            payload.text,
            "Compare \(secondRawReference) with \(firstRawReference)."
        )
        XCTAssertEqual(adapter.normalizeReadBack(payload.text), reordered)
    }

    func testReferencePreservingPlanReplacesOnlyPlainTextGapsFromEndToStart() {
        let rawReference = "\(fileIcon)\n\(filename)\n\(closeIcon)"
        let rawText = "Before \(rawReference) after"
        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawText,
            selectionRange: NSRange(location: rawText.utf16.count, length: 0),
            applicationName: "Cursor"
        )
        let editedText = "Start @\(filename) end 😀"

        let plan = adapter.referencePreservingCommitPlan(
            currentAccessibilityText: rawText,
            editedText: editedText,
            selectionRange: NSRange(location: editedText.utf16.count, length: 0)
        )

        XCTAssertEqual(plan?.replacements.count, 2)
        XCTAssertEqual(plan?.replacements.map(\.text), [" end 😀", "Start "])
        XCTAssertEqual(
            plan?.expectedAccessibilityText,
            "Start \(rawReference) end 😀"
        )
        XCTAssertEqual(
            plan?.finalSelectionRange.location,
            plan?.expectedAccessibilityText.utf16.count
        )
    }

    func testReferencePreservingPlanRejectsAChangedReferenceToken() {
        let rawText = "\(fileIcon)\n\(filename)\n\(closeIcon)"
        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawText,
            selectionRange: NSRange(location: 0, length: 0),
            applicationName: "Cursor"
        )

        let plan = adapter.referencePreservingCommitPlan(
            currentAccessibilityText: rawText,
            editedText: "@\(filename)Renamed",
            selectionRange: NSRange(location: 0, length: 0)
        )

        XCTAssertNil(plan)
    }

    func testReferencePlanUsesCurrentRangesWhenCursorDropsFocusPresentationText() {
        let rawReference = "\(fileIcon)\n\(filename)\n\(closeIcon)"
        let capturedText = "\n\(rawReference)\n"
        let currentUnfocusedText = rawReference
        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: capturedText,
            selectionRange: NSRange(location: 0, length: 0),
            applicationName: "Cursor"
        )
        let editedText = "\n@\(filename)\nExplain this"

        let plan = adapter.referencePreservingCommitPlan(
            currentAccessibilityText: currentUnfocusedText,
            editedText: editedText,
            selectionRange: NSRange(location: editedText.utf16.count, length: 0)
        )

        XCTAssertEqual(plan?.replacements.count, 2)
        XCTAssertEqual(plan?.replacements.map(\.range), [
            NSRange(location: currentUnfocusedText.utf16.count, length: 0),
            NSRange(location: 0, length: 0),
        ])
        XCTAssertEqual(plan?.replacements.map(\.text), ["\nExplain this", "\n"])
        XCTAssertEqual(
            plan?.expectedAccessibilityText,
            "\n\(rawReference)\nExplain this"
        )
    }

    func testPrivateUseTextOutsideCursorIsLeftUntouched() {
        let rawText = "\(fileIcon)\n\(filename)\n\(closeIcon)"

        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawText,
            selectionRange: NSRange(location: 2, length: 3),
            applicationName: "Notes"
        )

        XCTAssertEqual(adapter.editableText, rawText)
        XCTAssertEqual(adapter.editableSelectionRange, NSRange(location: 2, length: 3))
        XCTAssertEqual(adapter.adaptedReferenceCount, 0)
    }

    func testCursorTextWithoutAClosingChipIconIsLeftUntouched() {
        let rawText = "A legitimate private glyph: \(fileIcon)\nfilename.tsx"

        let adapter = AccessibilityTextContentAdapter.make(
            accessibilityText: rawText,
            selectionRange: NSRange(location: rawText.utf16.count, length: 0),
            applicationName: "Cursor"
        )

        XCTAssertEqual(adapter.editableText, rawText)
        XCTAssertEqual(adapter.adaptedReferenceCount, 0)
    }
}

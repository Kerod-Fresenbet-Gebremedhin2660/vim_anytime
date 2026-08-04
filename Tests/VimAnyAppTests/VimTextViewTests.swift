import AppKit
import VimAnyCore
import XCTest
@testable import VimAnyApp

@MainActor
final class VimTextViewTests: XCTestCase {
    func testSpellCheckingIsVisualOnlyAndCannotBypassNeovim() {
        let textView = VimTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let spellingReplacement = NSMenuItem(
            title: "replacement",
            action: #selector(NSTextView.changeSpelling(_:)),
            keyEquivalent: ""
        )

        XCTAssertTrue(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.validateUserInterfaceItem(spellingReplacement))

        let snapshot = EditorSnapshot(
            text: "A deliberatly misspeled sentence.",
            cursor: TextPosition(line: 0, utf8Column: 0),
            selection: nil,
            mode: .normal
        )
        textView.apply(snapshot: snapshot)
        textView.checkTextInDocument(nil)
        XCTAssertEqual(textView.string, snapshot.text)
    }

    func testAttributedInputCannotReplaceEditorFontOrCorruptUnicode() {
        let textView = VimTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.currentMode = .insert
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let expected = "abc 😀 二 ሰላም"
        let foreignFont = NSFont.systemFont(ofSize: 31, weight: .black)
        let attributedInput = NSAttributedString(
            string: expected,
            attributes: [
                .font: foreignFont,
                .foregroundColor: NSColor.systemRed,
            ]
        )
        var committedText: String?
        textView.onCommittedText = { committedText = $0 }

        textView.insertText(
            attributedInput,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(textView.string, expected)
        XCTAssertEqual(committedText, expected)
        guard let editorFont = textView.font else {
            XCTFail("VimTextView should retain its editor font")
            return
        }
        let string = textView.string as NSString
        textView.textStorage?.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        ) { value, range, _ in
            guard let renderedFont = value as? NSFont else {
                return XCTFail("Every rendered range should have a font")
            }
            XCTAssertNotEqual(renderedFont.fontName, foreignFont.fontName)
            XCTAssertEqual(renderedFont.pointSize, editorFont.pointSize)
            for scalar in string.substring(with: range).unicodeScalars {
                XCTAssertTrue(
                    renderedFont.coveredCharacterSet.contains(scalar),
                    "\(renderedFont.fontName) should cover U+\(String(scalar.value, radix: 16))"
                )
            }
        }
        let asciiTextFont = textView.textStorage?.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertEqual(asciiTextFont?.fontName, editorFont.fontName)
    }

    func testSnapshotRestoresStableTypingAttributes() throws {
        let textView = VimTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let snapshot = EditorSnapshot(
            text: "Unicode 😀 二 ሰላም",
            cursor: TextPosition(line: 0, utf8Column: 0),
            selection: nil,
            mode: .normal
        )

        XCTAssertEqual(textView.apply(snapshot: snapshot), true)

        let renderedFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let typingFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(renderedFont.fontName, typingFont.fontName)
        XCTAssertEqual(renderedFont.pointSize, typingFont.pointSize)
        XCTAssertEqual(textView.string, snapshot.text)
    }
}

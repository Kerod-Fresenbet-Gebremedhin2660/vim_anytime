import Foundation
import XCTest
@testable import VimAnyCore

final class TextCoordinateConverterTests: XCTestCase {
    func testASCIIAndMultilineCoordinates() {
        let text = "abc\ndefgh\n"
        XCTAssertEqual(
            TextCoordinateConverter.position(forUTF16Offset: 6, in: text),
            TextPosition(line: 1, utf8Column: 2)
        )
        XCTAssertEqual(
            TextCoordinateConverter.utf16Offset(
                for: TextPosition(line: 1, utf8Column: 2),
                in: text
            ),
            6
        )
        XCTAssertEqual(TextCoordinateConverter.lineCount(in: text), 3)
    }

    func testEmojiCJKAndAccentedCharactersUseUTF8ByteColumns() {
        let text = "a😀é中\nz"
        let nsText = text as NSString
        let emoji = nsText.range(of: "😀")
        let accent = nsText.range(of: "é")
        let cjk = nsText.range(of: "中")

        XCTAssertEqual(
            TextCoordinateConverter.position(forUTF16Offset: emoji.location, in: text),
            TextPosition(line: 0, utf8Column: 1)
        )
        XCTAssertEqual(
            TextCoordinateConverter.position(forUTF16Offset: NSMaxRange(emoji), in: text),
            TextPosition(line: 0, utf8Column: 5)
        )
        XCTAssertEqual(
            TextCoordinateConverter.position(forUTF16Offset: accent.location, in: text),
            TextPosition(line: 0, utf8Column: 5)
        )
        XCTAssertEqual(
            TextCoordinateConverter.position(forUTF16Offset: cjk.location, in: text),
            TextPosition(line: 0, utf8Column: 7)
        )
        XCTAssertEqual(
            TextCoordinateConverter.utf16Offset(
                for: TextPosition(line: 0, utf8Column: 10),
                in: text
            ),
            NSMaxRange(cjk)
        )
    }

    func testOffsetInsideSurrogatePairClampsToScalarBoundary() {
        let text = "a😀b"
        let emoji = (text as NSString).range(of: "😀")
        let invalidMiddle = emoji.location + 1
        XCTAssertEqual(
            TextCoordinateConverter.position(forUTF16Offset: invalidMiddle, in: text),
            TextPosition(line: 0, utf8Column: 1)
        )
    }

    func testByteColumnInsideUnicodeScalarClampsBackward() {
        let text = "a😀b"
        XCTAssertEqual(
            TextCoordinateConverter.utf16Offset(
                for: TextPosition(line: 0, utf8Column: 3),
                in: text
            ),
            1
        )
    }

    func testCharacterSelectionRoundTripsUnicodeAndMultipleLines() {
        let text = "zero 😀é中\nfamily 👩‍👩‍👧‍👦 plus e\u{301}\nend"
        let expected = (text as NSString).range(of: "😀é中\nfamily 👩‍👩‍👧‍👦")
        let selection = TextCoordinateConverter.editorSelection(
            fromUTF16Range: expected,
            in: text
        )
        let actual = TextCoordinateConverter.utf16Range(for: selection, in: text)
        XCTAssertEqual(actual, expected)
    }

    func testReversedVisualSelectionProducesForwardNSRange() {
        let text = "a😀bc"
        let selection = EditorSelection(
            anchor: TextPosition(line: 0, utf8Column: 5),
            head: TextPosition(line: 0, utf8Column: 1),
            kind: .character
        )
        XCTAssertEqual(
            TextCoordinateConverter.utf16Range(for: selection, in: text),
            (text as NSString).range(of: "😀b")
        )
    }

    func testLinewiseSelectionIncludesTrailingNewlineWhenPresent() {
        let text = "one\n二\nthree"
        let selection = EditorSelection(
            anchor: TextPosition(line: 1, utf8Column: 0),
            head: TextPosition(line: 0, utf8Column: 0),
            kind: .line
        )
        XCTAssertEqual(
            TextCoordinateConverter.utf16Range(for: selection, in: text),
            (text as NSString).range(of: "one\n二\n")
        )
    }

    func testDisplayColumnCountsGraphemeClustersNotBytes() {
        let text = "a👩‍👩‍👧‍👦e\u{301}z"
        let prefix = "a👩‍👩‍👧‍👦e\u{301}"
        let position = TextPosition(line: 0, utf8Column: prefix.utf8.count)
        XCTAssertEqual(TextCoordinateConverter.displayColumn(for: position, in: text), 4)
    }
}

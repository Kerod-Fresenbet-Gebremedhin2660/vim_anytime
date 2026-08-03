import AppKit
import XCTest
@testable import VimAnyCore

final class KeyTranslatorTests: XCTestCase {
    func testSpecialKeyExamples() {
        XCTAssertEqual(translate(keyCode: 53), .vim(VimKey("<Esc>")))
        XCTAssertEqual(translate(keyCode: 36, characters: "\r"), .vim(VimKey("<CR>")))
        XCTAssertEqual(translate(keyCode: 51), .vim(VimKey("<BS>")))
        XCTAssertEqual(translate(keyCode: 123), .vim(VimKey("<Left>")))
    }

    func testControlAndOptionExamples() {
        XCTAssertEqual(
            translate(keyCode: 13, characters: "\u{17}", ignoringModifiers: "w", modifiers: .control),
            .vim(VimKey("<C-w>"))
        )
        XCTAssertEqual(
            translate(keyCode: 11, characters: "∫", ignoringModifiers: "b", modifiers: .option),
            .vim(VimKey("<M-b>"))
        )
    }

    func testApplicationShortcutsAreReserved() {
        XCTAssertEqual(
            translate(keyCode: 36, characters: "\r", modifiers: .command),
            .application(.commitAndClose)
        )
        XCTAssertEqual(
            translate(keyCode: 1, characters: "s", ignoringModifiers: "s", modifiers: .command),
            .application(.commit)
        )
        XCTAssertEqual(
            translate(keyCode: 47, characters: ".", ignoringModifiers: ".", modifiers: .command),
            .application(.cancel)
        )
    }

    func testPrintableInsertInputUsesNativeTextSystem() {
        XCTAssertEqual(
            translate(keyCode: 0, characters: "é", ignoringModifiers: "e", mode: .insert),
            .useNativeTextInput
        )
    }

    func testColonStartsWhitelistedNativeExInput() {
        XCTAssertEqual(
            translate(keyCode: 41, characters: ":", ignoringModifiers: ":"),
            .beginExCommand
        )
        XCTAssertEqual(
            translate(
                keyCode: 13,
                characters: "w",
                ignoringModifiers: "w",
                isEnteringExCommand: true
            ),
            .appendExText("w")
        )
    }

    private func translate(
        keyCode: UInt16,
        characters: String = "",
        ignoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        mode: VimMode = .normal,
        isEnteringExCommand: Bool = false
    ) -> TranslatedKeyAction {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )!
        return KeyTranslator.translate(
            event: event,
            mode: mode,
            isEnteringExCommand: isEnteringExCommand
        )
    }
}

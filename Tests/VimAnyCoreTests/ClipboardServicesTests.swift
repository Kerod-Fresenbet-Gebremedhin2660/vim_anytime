import AppKit
import XCTest
@testable import VimAnyCore

@MainActor
final class ClipboardServicesTests: XCTestCase {
    func testVimLinewiseAndCharacterwiseConversions() {
        let pasteboard = makePasteboard()
        let clipboard = SystemClipboardService(pasteboard: pasteboard)

        clipboard.writeFromVim(lines: ["α", "β"], registerType: "V")
        XCTAssertEqual(clipboard.readText(), "α\nβ\n")
        XCTAssertEqual(clipboard.readForVim().lines, ["α", "β"])
        XCTAssertEqual(clipboard.readForVim().registerType, "V")

        clipboard.writeFromVim(lines: ["one", "two"], registerType: "v")
        XCTAssertEqual(clipboard.readText(), "one\ntwo")
        XCTAssertEqual(clipboard.readForVim().registerType, "v")
    }

    func testFallbackRestoresIntentionalYankAfterUnicodeMultilinePaste() async {
        let pasteboard = makePasteboard()
        let clipboard = SystemClipboardService(pasteboard: pasteboard)
        clipboard.writeTextIntentionally("intentional yank 🧪\nsecond line\n")
        let observed = LockedString()
        let fallback = ClipboardFallbackService(
            clipboard: clipboard,
            pasteAction: { _ in
                observed.value = clipboard.readText()
                return true
            },
            restorationDelayNanoseconds: 0
        )

        let result = await fallback.replace(
            text: "replacement 😀\nline 二",
            target: AccessibilityTextTarget(testProcessIdentifier: 0),
            focusTarget: {}
        )

        XCTAssertTrue(result)
        XCTAssertEqual(observed.value, "replacement 😀\nline 二")
        XCTAssertEqual(clipboard.readText(), "intentional yank 🧪\nsecond line\n")
    }

    func testFallbackDoesNotOverwriteIntentionalClipboardChangeDuringPaste() async {
        let pasteboard = makePasteboard()
        let clipboard = SystemClipboardService(pasteboard: pasteboard)
        clipboard.writeTextIntentionally("old yank")
        let fallback = ClipboardFallbackService(
            clipboard: clipboard,
            pasteAction: { _ in
                clipboard.writeTextIntentionally("new yank")
                return true
            },
            restorationDelayNanoseconds: 0
        )

        _ = await fallback.replace(
            text: "field text",
            target: AccessibilityTextTarget(testProcessIdentifier: 0),
            focusTarget: {}
        )
        XCTAssertEqual(clipboard.readText(), "new yank")
    }

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("dev.vimany.tests.\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}


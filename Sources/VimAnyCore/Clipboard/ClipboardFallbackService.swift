import ApplicationServices
import Foundation

@MainActor
public protocol ClipboardFallbackWriting: AnyObject {
    func replace(
        text: String,
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool
}

/// Uses the clipboard only as a transport for fields that reject AX value writes.
/// It never advances `SystemClipboardService`'s intentional-edit revision.
@MainActor
public final class ClipboardFallbackService: ClipboardFallbackWriting {
    public typealias PasteAction = @Sendable (pid_t) async -> Bool

    private let clipboard: SystemClipboardService
    private let logger = DiagnosticLogger.shared
    private let pasteAction: PasteAction
    private let restorationDelayNanoseconds: UInt64

    public init(
        clipboard: SystemClipboardService,
        pasteAction: PasteAction? = nil,
        restorationDelayNanoseconds: UInt64 = 80_000_000
    ) {
        self.clipboard = clipboard
        if let pasteAction {
            self.pasteAction = pasteAction
        } else {
            self.pasteAction = { processIdentifier in
                await ClipboardFallbackService.postSelectAllAndPaste(to: processIdentifier)
            }
        }
        self.restorationDelayNanoseconds = restorationDelayNanoseconds
    }

    public func replace(
        text: String,
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool {
        logger.info(
            "ClipboardFallback",
            "replacement started pid=\(target.processIdentifier) utf16Length=\(text.utf16.count)"
        )
        let archive = clipboard.archive()
        let temporaryChangeCount = clipboard.installTemporaryText(text)
        focusTarget()
        try? await Task.sleep(nanoseconds: 35_000_000)
        let didPaste = await pasteAction(target.processIdentifier)
        if restorationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: restorationDelayNanoseconds)
        }
        let didRestore = clipboard.restoreTemporaryArchive(
            archive,
            expectedChangeCount: temporaryChangeCount
        )
        logger.info(
            "ClipboardFallback",
            "replacement completed pid=\(target.processIdentifier) pasted=\(didPaste) "
                + "clipboardRestored=\(didRestore)"
        )
        return didPaste
    }

    nonisolated private static func postSelectAllAndPaste(to processIdentifier: pid_t) async -> Bool {
        guard AXIsProcessTrusted() else {
            DiagnosticLogger.shared.error(
                "ClipboardFallback",
                "synthetic paste blocked because Accessibility is not trusted"
            )
            return false
        }
        guard postCommandKey(keyCode: 0, to: processIdentifier) else {
            DiagnosticLogger.shared.error(
                "ClipboardFallback",
                "could not post Command-A pid=\(processIdentifier)"
            )
            return false
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let pasted = postCommandKey(keyCode: 9, to: processIdentifier)
        if !pasted {
            DiagnosticLogger.shared.error(
                "ClipboardFallback",
                "could not post Command-V pid=\(processIdentifier)"
            )
        }
        return pasted
    }

    nonisolated private static func postCommandKey(keyCode: CGKeyCode, to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }
}

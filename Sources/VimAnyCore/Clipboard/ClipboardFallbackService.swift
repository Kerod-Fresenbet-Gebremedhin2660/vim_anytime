import ApplicationServices
import Foundation

@MainActor
public protocol ClipboardFallbackWriting: AnyObject {
    func replace(
        text: String,
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool

    func replaceRanges(
        _ replacements: [AccessibilityTextReplacement],
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool
}

/// Uses the clipboard only as a transport for fields that reject AX value writes.
/// It never advances `SystemClipboardService`'s intentional-edit revision.
@MainActor
public final class ClipboardFallbackService: ClipboardFallbackWriting {
    public typealias PasteAction = @Sendable (pid_t) async -> Bool
    public typealias RangeReplacementAction = @Sendable (
        AccessibilityTextReplacement,
        AccessibilityTextTarget
    ) async -> Bool

    private let clipboard: SystemClipboardService
    private let logger = DiagnosticLogger.shared
    private let pasteAction: PasteAction
    private let rangeReplacementAction: RangeReplacementAction
    private let restorationDelayNanoseconds: UInt64

    public init(
        clipboard: SystemClipboardService,
        pasteAction: PasteAction? = nil,
        rangeReplacementAction: RangeReplacementAction? = nil,
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
        if let rangeReplacementAction {
            self.rangeReplacementAction = rangeReplacementAction
        } else {
            self.rangeReplacementAction = { replacement, target in
                await ClipboardFallbackService.postSelectionReplacement(
                    replacement,
                    to: target
                )
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

    public func replaceRanges(
        _ replacements: [AccessibilityTextReplacement],
        target: AccessibilityTextTarget,
        focusTarget: () -> Void
    ) async -> Bool {
        guard !replacements.isEmpty else {
            logger.debug("ClipboardFallback", "range replacement skipped because plan is empty")
            return true
        }
        guard zip(replacements, replacements.dropFirst()).allSatisfy({ pair in
            pair.0.range.location >= NSMaxRange(pair.1.range)
        }) else {
            logger.error("ClipboardFallback", "range replacement plan is not descending/nonoverlapping")
            return false
        }

        logger.info(
            "ClipboardFallback",
            "range replacement started pid=\(target.processIdentifier) "
                + "operationCount=\(replacements.count)"
        )
        let archive = clipboard.archive()
        var temporaryChangeCount: Int?
        var succeeded = true
        focusTarget()
        try? await Task.sleep(nanoseconds: 35_000_000)

        for replacement in replacements {
            if !replacement.text.isEmpty {
                temporaryChangeCount = clipboard.installTemporaryText(replacement.text)
            }
            let didReplace = await rangeReplacementAction(replacement, target)
            guard didReplace else {
                succeeded = false
                break
            }
            if restorationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: restorationDelayNanoseconds)
            }
        }

        let didRestore: Bool
        if let temporaryChangeCount {
            didRestore = clipboard.restoreTemporaryArchive(
                archive,
                expectedChangeCount: temporaryChangeCount
            )
        } else {
            didRestore = true
        }
        logger.info(
            "ClipboardFallback",
            "range replacement completed pid=\(target.processIdentifier) "
                + "succeeded=\(succeeded) clipboardRestored=\(didRestore)"
        )
        return succeeded
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

    nonisolated private static func postSelectionReplacement(
        _ replacement: AccessibilityTextReplacement,
        to target: AccessibilityTextTarget
    ) async -> Bool {
        guard AXIsProcessTrusted() else {
            DiagnosticLogger.shared.error(
                "ClipboardFallback",
                "range replacement blocked because Accessibility is not trusted"
            )
            return false
        }

        var range = CFRange(
            location: replacement.range.location,
            length: replacement.range.length
        )
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        let selectionResult = AXUIElementSetAttributeValue(
            target.textElement,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        guard selectionResult == .success else {
            DiagnosticLogger.shared.warning(
                "ClipboardFallback",
                "range selection failed pid=\(target.processIdentifier) "
                    + "error=\(selectionResult.rawValue) "
                    + "range=\(NSStringFromRange(replacement.range))"
            )
            return false
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        if replacement.text.isEmpty {
            return postKey(keyCode: 51, flags: [], to: target.processIdentifier)
        }
        // Cursor's plain-paste shortcut inserts text into the selected gap
        // without interpreting it as a new attachment or replacing adjacent
        // rich reference nodes.
        return postKey(
            keyCode: 9,
            flags: [.maskCommand, .maskShift],
            to: target.processIdentifier
        )
    }

    nonisolated private static func postCommandKey(keyCode: CGKeyCode, to processIdentifier: pid_t) -> Bool {
        postKey(keyCode: keyCode, flags: .maskCommand, to: processIdentifier)
    }

    nonisolated private static func postKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        to processIdentifier: pid_t
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }
}

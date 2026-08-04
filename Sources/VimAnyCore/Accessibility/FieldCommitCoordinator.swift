import Foundation

public enum FieldCommitResult: Equatable, Sendable {
    case direct
    case clipboardFallback
    case copiedToClipboard
    case failed
}

/// Owns one captured field session, keeping panel code independent from AX and fallback details.
@MainActor
public final class FieldCommitCoordinator {
    private let logger = DiagnosticLogger.shared
    private let accessibility: AccessibilityTextServicing
    private let fallback: ClipboardFallbackWriting
    private let clipboard: IntentionalClipboardWriting
    public private(set) var capturedField: CapturedTextField?

    public init(
        accessibility: AccessibilityTextServicing,
        fallback: ClipboardFallbackWriting,
        clipboard: IntentionalClipboardWriting
    ) {
        self.accessibility = accessibility
        self.fallback = fallback
        self.clipboard = clipboard
    }

    @discardableResult
    public func begin() throws -> CapturedTextField {
        logger.info("Commit", "field session begin")
        let capture = try accessibility.captureFocusedTextField()
        capturedField = capture
        logger.info(
            "Commit",
            "field session captured pid=\(capture.target.processIdentifier) "
                + "utf16Length=\(capture.text.utf16.count)"
        )
        return capture
    }

    public func commit(
        text: String,
        selectionRange: NSRange,
        restoreFocus: Bool,
        copyTextToClipboardOnFailure: Bool = false
    ) async -> FieldCommitResult {
        guard let capturedField else {
            logger.error("Commit", "commit requested without a captured field")
            return .failed
        }
        logger.info(
            "Commit",
            "commit started pid=\(capturedField.target.processIdentifier) "
                + "utf16Length=\(text.utf16.count) selection=\(NSStringFromRange(selectionRange)) "
                + "restoreFocus=\(restoreFocus) "
                + "copyOnFailure=\(copyTextToClipboardOnFailure)"
        )

        if accessibility.write(text: text, selectionRange: selectionRange, to: capturedField.target) {
            if verifyWrittenText(text, in: capturedField.target, strategy: "directAX") {
                if restoreFocus { accessibility.restoreFocus(to: capturedField.target) }
                logger.info("Commit", "commit completed strategy=directAX")
                return .direct
            }
            logger.warning(
                "Commit",
                "direct AX write reported success but read-back verification failed"
            )
        } else {
            logger.warning("Commit", "direct AX write rejected")
        }

        logger.warning("Commit", "starting clipboard fallback")
        let didPaste = await fallback.replace(text: text, target: capturedField.target) { [accessibility] in
            accessibility.restoreFocus(to: capturedField.target)
        }
        if didPaste,
           verifyWrittenText(text, in: capturedField.target, strategy: "clipboardFallback") {
            accessibility.writeSelection(selectionRange, to: capturedField.target)
            logger.info("Commit", "commit completed strategy=clipboardFallback")
            return .clipboardFallback
        }
        if didPaste {
            logger.error(
                "Commit",
                "clipboard fallback posted paste but read-back verification failed"
            )
        } else {
            logger.error("Commit", "clipboard fallback could not post paste")
        }
        if copyTextToClipboardOnFailure {
            if clipboard.writeTextIntentionally(text) {
                logger.warning(
                    "Commit",
                    "field write failed; edited text copied intentionally to clipboard "
                        + "utf16Length=\(text.utf16.count)"
                )
                return .copiedToClipboard
            }
            logger.error("Commit", "last-resort edited-text clipboard write failed")
        }
        return .failed
    }

    private func verifyWrittenText(
        _ expectedText: String,
        in target: AccessibilityTextTarget,
        strategy: String
    ) -> Bool {
        guard let actualText = accessibility.readText(from: target) else {
            logger.warning(
                "Commit",
                "write verification unavailable strategy=\(strategy) "
                    + "expectedUTF16Length=\(expectedText.utf16.count)"
            )
            return false
        }
        guard actualText == expectedText else {
            logger.warning(
                "Commit",
                "write verification mismatch strategy=\(strategy) "
                    + "expectedUTF16Length=\(expectedText.utf16.count) "
                    + "actualUTF16Length=\(actualText.utf16.count)"
            )
            return false
        }
        logger.debug(
            "Commit",
            "write verification succeeded strategy=\(strategy) "
                + "utf16Length=\(expectedText.utf16.count)"
        )
        return true
    }

    public func cancel() {
        guard let capturedField else {
            logger.debug("Commit", "cancel ignored because no field session is active")
            return
        }
        logger.info("Commit", "field session canceled pid=\(capturedField.target.processIdentifier)")
        accessibility.restoreFocus(to: capturedField.target)
        self.capturedField = nil
    }

    public func finish() {
        if let capturedField {
            logger.info("Commit", "field session finished pid=\(capturedField.target.processIdentifier)")
        }
        capturedField = nil
    }
}

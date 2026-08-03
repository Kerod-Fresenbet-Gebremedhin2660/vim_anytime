import Foundation

public enum FieldCommitResult: Equatable, Sendable {
    case direct
    case clipboardFallback
    case failed
}

/// Owns one captured field session, keeping panel code independent from AX and fallback details.
@MainActor
public final class FieldCommitCoordinator {
    private let logger = DiagnosticLogger.shared
    private let accessibility: AccessibilityTextServicing
    private let fallback: ClipboardFallbackWriting
    public private(set) var capturedField: CapturedTextField?

    public init(
        accessibility: AccessibilityTextServicing,
        fallback: ClipboardFallbackWriting
    ) {
        self.accessibility = accessibility
        self.fallback = fallback
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
        restoreFocus: Bool
    ) async -> FieldCommitResult {
        guard let capturedField else {
            logger.error("Commit", "commit requested without a captured field")
            return .failed
        }
        logger.info(
            "Commit",
            "commit started pid=\(capturedField.target.processIdentifier) "
                + "utf16Length=\(text.utf16.count) selection=\(NSStringFromRange(selectionRange)) "
                + "restoreFocus=\(restoreFocus)"
        )

        if accessibility.write(text: text, selectionRange: selectionRange, to: capturedField.target) {
            if restoreFocus { accessibility.restoreFocus(to: capturedField.target) }
            logger.info("Commit", "commit completed strategy=directAX")
            return .direct
        }

        logger.warning("Commit", "direct AX write rejected; starting clipboard fallback")
        let didPaste = await fallback.replace(text: text, target: capturedField.target) { [accessibility] in
            accessibility.restoreFocus(to: capturedField.target)
        }
        if didPaste {
            accessibility.writeSelection(selectionRange, to: capturedField.target)
            logger.info("Commit", "commit completed strategy=clipboardFallback")
            return .clipboardFallback
        }
        logger.error("Commit", "clipboard fallback failed")
        return .failed
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

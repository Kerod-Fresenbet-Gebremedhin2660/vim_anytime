import Foundation

public enum FieldCommitResult: Equatable, Sendable {
    case direct
    case referencePreserving
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

        if capturedField.contentAdapter.requiresReferencePreservingCommit {
            return await commitPreservingReferences(
                text: text,
                selectionRange: selectionRange,
                copyTextToClipboardOnFailure: copyTextToClipboardOnFailure,
                capturedField: capturedField
            )
        }

        let directPayload = capturedField.contentAdapter.directWritePayload(
            editableText: text,
            selectionRange: selectionRange
        )
        if accessibility.write(
            text: directPayload.text,
            selectionRange: directPayload.selectionRange,
            to: capturedField.target
        ) {
            if verifyWrittenText(
                text,
                selectionRange: selectionRange,
                in: capturedField,
                strategy: "directAX"
            ) != nil {
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
           let verifiedSelectionRange = verifyWrittenText(
               text,
               selectionRange: selectionRange,
               in: capturedField,
               strategy: "clipboardFallback"
           ) {
            accessibility.writeSelection(verifiedSelectionRange, to: capturedField.target)
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

    private func commitPreservingReferences(
        text: String,
        selectionRange: NSRange,
        copyTextToClipboardOnFailure: Bool,
        capturedField: CapturedTextField
    ) async -> FieldCommitResult {
        logger.info("Commit", "structured reference preservation strategy selected")
        // Cursor changes the AXValue boundary representation when its prompt
        // gains or loses focus. Focus first, then read and edit in one stable
        // coordinate space; planning while VimAny owns focus produces ranges
        // that are already stale by the time synthetic paste is delivered.
        accessibility.restoreFocus(to: capturedField.target)
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let currentAccessibilityText = accessibility.readText(from: capturedField.target),
              let plan = capturedField.contentAdapter.referencePreservingCommitPlan(
                  currentAccessibilityText: currentAccessibilityText,
                  editedText: text,
                  selectionRange: selectionRange
              ) else {
            logger.error(
                "Commit",
                "structured references changed or are unavailable; destructive replacement skipped"
            )
            return copyOrFail(
                text: text,
                copyTextToClipboardOnFailure: copyTextToClipboardOnFailure
            )
        }

        if plan.replacements.isEmpty {
            accessibility.writeSelection(plan.finalSelectionRange, to: capturedField.target)
            logger.info("Commit", "structured reference commit completed without text changes")
            return .referencePreserving
        }

        let didReplace = await fallback.replaceRanges(
            plan.replacements,
            target: capturedField.target
        ) { [accessibility] in
            accessibility.restoreFocus(to: capturedField.target)
        }
        let verifiedSelectionRange = verifyWrittenText(
            text,
            selectionRange: selectionRange,
            in: capturedField,
            strategy: "referencePreservingRanges"
        )
        if let verifiedSelectionRange {
            accessibility.writeSelection(verifiedSelectionRange, to: capturedField.target)
            logger.info(
                "Commit",
                "structured reference commit completed operationCount=\(plan.replacements.count) "
                    + "eventsReportedSuccess=\(didReplace)"
            )
            return .referencePreserving
        }

        logger.error(
            "Commit",
            "structured reference range commit failed verification; whole-field fallback skipped"
        )
        return copyOrFail(
            text: text,
            copyTextToClipboardOnFailure: copyTextToClipboardOnFailure
        )
    }

    private func copyOrFail(
        text: String,
        copyTextToClipboardOnFailure: Bool
    ) -> FieldCommitResult {
        guard copyTextToClipboardOnFailure else { return .failed }
        if clipboard.writeTextIntentionally(text) {
            logger.warning(
                "Commit",
                "edited text copied intentionally because a safe field write was unavailable "
                    + "utf16Length=\(text.utf16.count)"
            )
            return .copiedToClipboard
        }
        logger.error("Commit", "last-resort edited-text clipboard write failed")
        return .failed
    }

    private func verifyWrittenText(
        _ expectedText: String,
        selectionRange: NSRange,
        in capturedField: CapturedTextField,
        strategy: String
    ) -> NSRange? {
        guard let actualText = accessibility.readText(from: capturedField.target) else {
            logger.warning(
                "Commit",
                "write verification unavailable strategy=\(strategy) "
                    + "expectedUTF16Length=\(expectedText.utf16.count)"
            )
            return nil
        }
        let normalizedText = capturedField.contentAdapter.normalizeReadBack(actualText)
        guard normalizedText == expectedText else {
            logger.warning(
                "Commit",
                "write verification mismatch strategy=\(strategy) "
                    + "expectedUTF16Length=\(expectedText.utf16.count) "
                    + "actualUTF16Length=\(actualText.utf16.count)"
            )
            return nil
        }
        logger.debug(
            "Commit",
            "write verification succeeded strategy=\(strategy) "
                + "utf16Length=\(expectedText.utf16.count)"
        )
        return capturedField.contentAdapter.selectionRange(
            inReadBack: actualText,
            editableText: expectedText,
            editableSelectionRange: selectionRange
        )
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

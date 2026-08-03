import Foundation

public enum FieldCommitResult: Equatable, Sendable {
    case direct
    case clipboardFallback
    case failed
}

/// Owns one captured field session, keeping panel code independent from AX and fallback details.
@MainActor
public final class FieldCommitCoordinator {
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
        let capture = try accessibility.captureFocusedTextField()
        capturedField = capture
        return capture
    }

    public func commit(
        text: String,
        selectionRange: NSRange,
        restoreFocus: Bool
    ) async -> FieldCommitResult {
        guard let capturedField else { return .failed }

        if accessibility.write(text: text, selectionRange: selectionRange, to: capturedField.target) {
            if restoreFocus { accessibility.restoreFocus(to: capturedField.target) }
            return .direct
        }

        let didPaste = await fallback.replace(text: text, target: capturedField.target) { [accessibility] in
            accessibility.restoreFocus(to: capturedField.target)
        }
        if didPaste {
            accessibility.writeSelection(selectionRange, to: capturedField.target)
            return .clipboardFallback
        }
        return .failed
    }

    public func cancel() {
        guard let capturedField else { return }
        accessibility.restoreFocus(to: capturedField.target)
        self.capturedField = nil
    }

    public func finish() {
        capturedField = nil
    }
}

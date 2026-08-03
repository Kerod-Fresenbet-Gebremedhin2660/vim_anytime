import AppKit
import VimAnyCore

@MainActor
final class VimTextView: NSTextView, NSTextViewDelegate {
    var currentMode: VimMode = .normal
    var isEnteringExCommand: (() -> Bool)?
    var onKeyAction: ((TranslatedKeyAction) -> Void)?
    var onCommittedText: ((String) -> Void)?
    var onNativeSelection: ((EditorSelection) -> Void)?

    private var isApplyingSnapshot = false
    private var isFinalizingMarkedText = false
    private var deferredSnapshot: EditorSnapshot?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        delegate = self
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        usesFindPanel = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        insertionPointColor = .controlAccentColor
        font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        textContainerInset = NSSize(width: 16, height: 14)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
    }

    override func keyDown(with event: NSEvent) {
        let action = KeyTranslator.translate(
            event: event,
            mode: currentMode,
            isEnteringExCommand: isEnteringExCommand?() == true
        )
        if action == .useNativeTextInput {
            interpretKeyEvents([event])
        } else {
            onKeyAction?(action)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let action = KeyTranslator.translate(
            event: event,
            mode: currentMode,
            isEnteringExCommand: isEnteringExCommand?() == true
        )
        if case .application = action {
            onKeyAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = insertString as? NSAttributedString {
            text = attributed.string
        } else if let string = insertString as? String {
            text = string
        } else {
            text = String(describing: insertString)
        }

        let wasMarked = hasMarkedText()
        if wasMarked {
            isFinalizingMarkedText = true
            super.insertText(insertString, replacementRange: replacementRange)
            isFinalizingMarkedText = false
        }
        onCommittedText?(text)

        if let deferredSnapshot {
            self.deferredSnapshot = nil
            apply(snapshot: deferredSnapshot)
        }
    }

    override func doCommand(by selector: Selector) {
        let notation: String?
        switch selector {
        case #selector(insertNewline(_:)): notation = "<CR>"
        case #selector(deleteBackward(_:)): notation = "<BS>"
        case #selector(deleteForward(_:)): notation = "<Del>"
        case #selector(moveLeft(_:)): notation = "<Left>"
        case #selector(moveRight(_:)): notation = "<Right>"
        case #selector(moveUp(_:)): notation = "<Up>"
        case #selector(moveDown(_:)): notation = "<Down>"
        case #selector(insertTab(_:)): notation = "<Tab>"
        case #selector(cancelOperation(_:)): notation = "<Esc>"
        default: notation = nil
        }
        if let notation {
            onKeyAction?(.vim(VimKey(notation)))
        } else {
            NSSound.beep()
        }
    }

    func apply(snapshot: EditorSnapshot) {
        guard !hasMarkedText() else {
            deferredSnapshot = snapshot
            return
        }

        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        currentMode = snapshot.mode

        if string != snapshot.text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
            textStorage?.setAttributedString(NSAttributedString(string: snapshot.text, attributes: attributes))
        }

        let requestedRange: NSRange
        if let selection = snapshot.selection {
            requestedRange = TextCoordinateConverter.utf16Range(for: selection, in: snapshot.text)
        } else {
            requestedRange = NSRange(
                location: TextCoordinateConverter.utf16Offset(for: snapshot.cursor, in: snapshot.text),
                length: 0
            )
        }
        let count = snapshot.text.utf16.count
        let location = min(max(0, requestedRange.location), count)
        let length = min(max(0, requestedRange.length), count - location)
        let range = NSRange(location: location, length: length)
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingSnapshot, !isFinalizingMarkedText, !hasMarkedText() else { return }
        let selection = TextCoordinateConverter.editorSelection(
            fromUTF16Range: selectedRange(),
            in: string
        )
        onNativeSelection?(selection)
    }
}


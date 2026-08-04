import AppKit
import VimAnyCore

@MainActor
final class VimTextView: NSTextView, NSTextViewDelegate {
    private let logger = DiagnosticLogger.shared
    var currentMode: VimMode = .normal
    var isEnteringExCommand: (() -> Bool)?
    var onKeyAction: ((TranslatedKeyAction) -> Void)?
    var onCommittedText: ((String) -> Void)?
    var onNativeSelection: ((EditorSelection) -> Void)?

    private var isApplyingSnapshot = false
    private var isFinalizingMarkedText = false
    private var deferredSnapshot: EditorSnapshot?
    private var cursorUTF16Offset = 0
    private var isConfigured = false
    private var lastReplacementCharacterCount = 0
    private let editorFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    private var editorTextAttributes: [NSAttributedString.Key: Any] {
        [
            .font: editorFont,
            .foregroundColor: NSColor.textColor,
        ]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        delegate = self
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        usesFindPanel = false
        drawsBackground = false
        backgroundColor = .clear
        textColor = .textColor
        insertionPointColor = .controlAccentColor
        font = editorFont
        typingAttributes = editorTextAttributes
        textContainerInset = NSSize(width: 16, height: 14)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        logger.info(
            "TextView",
            "configured textStorageAvailable=\(textStorage != nil) "
                + "layoutManagerAvailable=\(layoutManager != nil) "
                + "textContainerAvailable=\(textContainer != nil) "
                + "font=\(editorFont.fontName) pointSize=\(editorFont.pointSize) "
                + "spellChecking=\(isContinuousSpellCheckingEnabled) "
                + "automaticCorrection=\(isAutomaticSpellingCorrectionEnabled)"
        )
    }

    override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        // AppKit's spelling replacement would mutate NSTextStorage directly,
        // bypassing Neovim's undo tree and dot-repeat state. Keep native
        // underlines and dictionary actions, but do not enable replacement
        // until it can be routed through NvimEditingEngine as a structured edit.
        if item.action == #selector(changeSpelling(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func changeSpelling(_ sender: Any?) {
        logger.warning(
            "TextView",
            "native spelling replacement ignored to preserve Neovim state"
        )
        NSSound.beep()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard currentMode.usesBlockCursor,
              window?.firstResponder === self,
              let cursorRect = blockCursorRect(),
              dirtyRect.intersects(cursorRect) else { return }

        NSColor.controlAccentColor.withAlphaComponent(0.58).setFill()
        cursorRect.fill(using: .sourceOver)

        if currentMode.isVisual {
            let outline = cursorRect.insetBy(dx: 0.5, dy: 0.5)
            NSColor.textColor.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(rect: outline)
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        guard !currentMode.usesBlockCursor else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { needsDisplay = true }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { needsDisplay = true }
        return resignedFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        let action = KeyTranslator.translate(
            event: event,
            mode: currentMode,
            isEnteringExCommand: isEnteringExCommand?() == true
        )
        logger.debug("TextView", "keyDown action=\(Self.describe(action)) mode=\(currentMode.displayName)")
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
        let inputKind: String
        if let attributed = insertString as? NSAttributedString {
            text = attributed.string
            inputKind = "attributed"
        } else if let string = insertString as? String {
            text = string
            inputKind = "plain"
        } else {
            text = String(describing: insertString)
            inputKind = "other"
        }

        // Keep the AppKit surface responsive while Neovim remains authoritative.
        // AppKit input methods may commit an attributed string containing a font
        // intended only for their candidate UI. Insert its plain text with our
        // stable typing attributes so those foreign attributes cannot render as
        // missing-glyph boxes. Neovim remains authoritative and the following
        // snapshot reconciles replace-mode and other semantics.
        let insertionLocation = effectiveInsertionLocation(for: replacementRange)
        isFinalizingMarkedText = true
        typingAttributes = editorTextAttributes
        super.insertText(text, replacementRange: replacementRange)
        applyEditorAttributes(
            to: NSRange(location: insertionLocation, length: text.utf16.count)
        )
        typingAttributes = editorTextAttributes
        isFinalizingMarkedText = false
        logger.debug(
            "TextView",
            "committed native text utf16Length=\(text.utf16.count) "
                + "replacementRange=\(NSStringFromRange(replacementRange)) "
                + "inputKind=\(inputKind) "
                + "replacementCharacters=\(Self.replacementCharacterCount(in: text))"
        )
        onCommittedText?(text)

        // A snapshot deferred during composition predates this committed text.
        // Discard it instead of briefly painting stale contents; the queued edit
        // always publishes a fresh authoritative snapshot.
        deferredSnapshot = nil
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
            logger.debug("TextView", "native command selector=\(selector) notation=\(notation)")
            onKeyAction?(.vim(VimKey(notation)))
        } else {
            logger.warning("TextView", "unsupported native command selector=\(selector)")
            NSSound.beep()
        }
    }

    @discardableResult
    func apply(snapshot: EditorSnapshot) -> Bool? {
        guard !hasMarkedText() else {
            logger.debug("TextView", "snapshot deferred during marked-text composition")
            deferredSnapshot = snapshot
            return nil
        }

        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        currentMode = snapshot.mode

        let textChanged = string != snapshot.text
        if textChanged {
            guard let textStorage else {
                logger.error("TextView", "cannot render snapshot because NSTextStorage is missing")
                return nil
            }
            textStorage.setAttributedString(
                NSAttributedString(string: snapshot.text, attributes: editorTextAttributes)
            )
        }
        typingAttributes = editorTextAttributes

        let replacementCharacterCount = Self.replacementCharacterCount(in: snapshot.text)
        if replacementCharacterCount != lastReplacementCharacterCount {
            lastReplacementCharacterCount = replacementCharacterCount
            if replacementCharacterCount > 0 {
                logger.warning(
                    "TextView",
                    "snapshot contains Unicode replacement characters "
                        + "count=\(replacementCharacterCount)"
                )
            }
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
        cursorUTF16Offset = min(
            max(0, TextCoordinateConverter.utf16Offset(for: snapshot.cursor, in: snapshot.text)),
            count
        )
        setSelectedRange(range)
        scrollRangeToVisible(range)
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(true)
        logger.debug(
            "TextView",
            "snapshot applied mode=\(snapshot.mode.displayName) textChanged=\(textChanged) "
                + "utf16Length=\(count) selection=\(NSStringFromRange(range)) "
                + "cursorOffset=\(cursorUTF16Offset) frame=\(NSStringFromRect(frame))"
        )
        return textChanged
    }

    private func effectiveInsertionLocation(for replacementRange: NSRange) -> Int {
        let textLength = (string as NSString).length
        let requestedLocation = replacementRange.location == NSNotFound
            ? selectedRange().location
            : replacementRange.location
        return min(max(0, requestedLocation), textLength)
    }

    private func applyEditorAttributes(to requestedRange: NSRange) {
        guard requestedRange.length > 0, let textStorage else { return }
        let storageLength = textStorage.length
        let location = min(max(0, requestedRange.location), storageLength)
        let length = min(max(0, requestedRange.length), storageLength - location)
        guard length > 0 else { return }
        textStorage.addAttributes(
            editorTextAttributes,
            range: NSRange(location: location, length: length)
        )
    }

    private static func replacementCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value == 0xFFFD { count += 1 }
        }
    }

    private func blockCursorRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }

        layoutManager.ensureLayout(for: textContainer)
        let textLength = (string as NSString).length
        let offset = min(max(0, cursorUTF16Offset), textLength)
        let cellWidth = max(
            2,
            ceil((" " as NSString).size(withAttributes: [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            ]).width)
        )

        var rect: NSRect
        if offset < textLength {
            let characterRange = (string as NSString).rangeOfComposedCharacterSequence(at: offset)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }

            rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            rect.origin.y = lineRect.origin.y
            rect.size.height = lineRect.height
        } else if layoutManager.extraLineFragmentTextContainer === textContainer {
            rect = layoutManager.extraLineFragmentUsedRect
            if rect.height <= 0 {
                rect = layoutManager.extraLineFragmentRect
            }
        } else if textLength > 0 {
            let finalCharacterRange = (string as NSString)
                .rangeOfComposedCharacterSequence(at: textLength - 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: finalCharacterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }

            let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            rect = NSRect(x: glyphRect.maxX, y: lineRect.minY, width: cellWidth, height: lineRect.height)
        } else {
            rect = NSRect(
                x: 0,
                y: 0,
                width: cellWidth,
                height: layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 15))
            )
        }

        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(cellWidth, rect.width)
        if rect.height <= 0 {
            rect.size.height = layoutManager.defaultLineHeight(
                for: font ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            )
        }
        return rect.integral
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingSnapshot, !isFinalizingMarkedText, !hasMarkedText() else { return }
        let selection = TextCoordinateConverter.editorSelection(
            fromUTF16Range: selectedRange(),
            in: string
        )
        logger.debug(
            "TextView",
            "native selection callback range=\(NSStringFromRange(selectedRange())) "
                + "kind=\(String(describing: selection.kind))"
        )
        onNativeSelection?(selection)
    }

    private static func describe(_ action: TranslatedKeyAction) -> String {
        switch action {
        case .application(let command):
            return "application(\(String(describing: command)))"
        case .vim(let key):
            if key.notation.hasPrefix("<"), key.notation.hasSuffix(">") {
                return "vimSpecial(\(key.notation))"
            }
            return "vimPrintable(characterCount=\(key.notation.count))"
        case .useNativeTextInput:
            return "nativeTextInput"
        case .beginExCommand:
            return "beginExCommand"
        case .appendExText(let text):
            return "appendExText(characterCount=\(text.count))"
        case .deleteExCharacter:
            return "deleteExCharacter"
        case .submitExCommand:
            return "submitExCommand"
        case .cancelExCommand:
            return "cancelExCommand"
        case .ignored:
            return "ignored"
        }
    }
}

private extension VimMode {
    var usesBlockCursor: Bool {
        switch self {
        case .normal, .operatorPending, .visual, .visualLine:
            return true
        default:
            return false
        }
    }

    var isVisual: Bool {
        self == .visual || self == .visualLine
    }
}

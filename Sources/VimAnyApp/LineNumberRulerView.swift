import AppKit

@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var editorTextView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var currentLine = 0
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        editorTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
        reservedThicknessForAccessoryView = 0
        reservedThicknessForMarkers = 0
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(observedViewChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(observedViewChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(text: String?, currentLine: Int) {
        if let text {
            lineStarts = Self.lineStarts(in: text)
        }
        self.currentLine = min(max(0, currentLine), lineStarts.count - 1)

        let digitCount = max(2, String(lineStarts.count).count)
        let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: numberFont]).width)
        ruleThickness = max(38, CGFloat(digitCount) * digitWidth + 16)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        guard let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let visibleRect = textView.visibleRect
        let origin = textView.textContainerOrigin
        let containerVisibleRect = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: containerVisibleRect,
            in: textContainer
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let firstLine = max(0, lineIndex(containing: characterRange.location) - 1)
        let lastCharacter = min(
            (textView.string as NSString).length,
            NSMaxRange(characterRange)
        )
        let lastLine = min(lineStarts.count - 1, lineIndex(containing: lastCharacter) + 1)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let labelHeight = ceil(numberFont.boundingRectForFont.height)
        let textLength = (textView.string as NSString).length

        for lineIndex in firstLine...lastLine {
            guard let lineRect = lineFragmentRect(
                forUTF16Offset: lineStarts[lineIndex],
                textLength: textLength,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else { continue }

            let viewPoint = NSPoint(x: 0, y: lineRect.minY + origin.y)
            let rulerY = convert(viewPoint, from: textView).y
            let drawingRect = NSRect(
                x: 3,
                y: rulerY + floor(max(0, lineRect.height - labelHeight) / 2),
                width: ruleThickness - 10,
                height: labelHeight
            )
            guard rect.intersects(drawingRect) else { continue }

            let color: NSColor = lineIndex == currentLine ? .labelColor : .tertiaryLabelColor
            String(lineIndex + 1).draw(
                in: drawingRect,
                withAttributes: [
                    .font: numberFont,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ]
            )
        }

        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    @objc private func observedViewChanged() {
        needsDisplay = true
    }

    private func lineIndex(containing utf16Offset: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lineStarts[middle] <= utf16Offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(0, lowerBound - 1)
    }

    private func lineFragmentRect(
        forUTF16Offset offset: Int,
        textLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        if offset < textLength {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: offset)
            return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        if layoutManager.extraLineFragmentTextContainer === textContainer {
            let usedRect = layoutManager.extraLineFragmentUsedRect
            return usedRect.height > 0 ? usedRect : layoutManager.extraLineFragmentRect
        }
        return nil
    }

    private static func lineStarts(in text: String) -> [Int] {
        var starts = [0]
        for (offset, codeUnit) in text.utf16.enumerated() where codeUnit == 0x0A {
            starts.append(offset + 1)
        }
        return starts
    }
}

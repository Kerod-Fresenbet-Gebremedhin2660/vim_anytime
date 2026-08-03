import Foundation

/// Converts between Neovim's line/UTF-8-byte coordinates and AppKit's UTF-16 ranges.
/// No caller should ever feed a Neovim byte column directly to `NSRange`.
public enum TextCoordinateConverter {
    public static func position(forUTF16Offset requestedOffset: Int, in text: String) -> TextPosition {
        let index = stringIndex(forUTF16Offset: requestedOffset, in: text)
        var line = 0
        var lineStart = text.startIndex
        var cursor = text.startIndex

        while cursor < index {
            if text[cursor] == "\n" {
                line += 1
                lineStart = text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }

        let byteColumn = text[lineStart..<index].utf8.count
        return TextPosition(line: line, utf8Column: byteColumn)
    }

    public static func utf16Offset(for position: TextPosition, in text: String) -> Int {
        let index = stringIndex(for: position, in: text)
        return text.utf16.distance(
            from: text.utf16.startIndex,
            to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex
        )
    }

    public static func editorSelection(fromUTF16Range range: NSRange, in text: String) -> EditorSelection {
        guard range.location != NSNotFound else {
            return .caret(at: TextPosition(line: 0, utf8Column: 0))
        }

        let utf16Count = text.utf16.count
        let startOffset = min(max(0, range.location), utf16Count)
        let requestedEnd = range.location > Int.max - max(0, range.length)
            ? utf16Count
            : range.location + max(0, range.length)
        let endOffset = min(max(startOffset, requestedEnd), utf16Count)
        let anchor = position(forUTF16Offset: startOffset, in: text)

        guard endOffset > startOffset else {
            return .caret(at: anchor)
        }

        let exclusiveEnd = stringIndex(forUTF16Offset: endOffset, in: text)
        let inclusiveEnd = exclusiveEnd > text.startIndex
            ? text.index(before: exclusiveEnd)
            : text.startIndex
        let headOffset = text.utf16.distance(
            from: text.utf16.startIndex,
            to: inclusiveEnd.samePosition(in: text.utf16) ?? text.utf16.startIndex
        )
        let head = position(forUTF16Offset: headOffset, in: text)
        return EditorSelection(anchor: anchor, head: head, kind: .character)
    }

    public static func utf16Range(for selection: EditorSelection, in text: String) -> NSRange {
        switch selection.kind {
        case .caret:
            return NSRange(location: utf16Offset(for: selection.head, in: text), length: 0)

        case .character:
            let anchorIndex = stringIndex(for: selection.anchor, in: text)
            let headIndex = stringIndex(for: selection.head, in: text)
            let lowerIndex = min(anchorIndex, headIndex)
            let upperIndex = max(anchorIndex, headIndex)
            let exclusiveUpper = upperIndex < text.endIndex
                ? text.index(after: upperIndex)
                : text.endIndex
            return nsRange(from: lowerIndex, to: exclusiveUpper, in: text)

        case .line:
            let lowerLine = min(selection.anchor.line, selection.head.line)
            let upperLine = max(selection.anchor.line, selection.head.line)
            let lowerIndex = lineStart(forZeroBasedLine: lowerLine, in: text)
            let upperStart = lineStart(forZeroBasedLine: upperLine, in: text)
            let exclusiveUpper: String.Index
            if let newline = text[upperStart...].firstIndex(of: "\n") {
                exclusiveUpper = text.index(after: newline)
            } else {
                exclusiveUpper = text.endIndex
            }
            return nsRange(from: lowerIndex, to: exclusiveUpper, in: text)
        }
    }

    public static func displayColumn(for position: TextPosition, in text: String) -> Int {
        let index = stringIndex(for: position, in: text)
        let start = lineStart(forZeroBasedLine: position.line, in: text)
        guard start <= index else { return 1 }
        return text[start..<index].count + 1
    }

    public static func lineCount(in text: String) -> Int {
        max(1, text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
    }

    private static func nsRange(
        from start: String.Index,
        to end: String.Index,
        in text: String
    ) -> NSRange {
        let utf16 = text.utf16
        let utf16Start = start.samePosition(in: utf16) ?? utf16.startIndex
        let utf16End = end.samePosition(in: utf16) ?? utf16.endIndex
        let location = utf16.distance(from: utf16.startIndex, to: utf16Start)
        let length = utf16.distance(from: utf16Start, to: utf16End)
        return NSRange(location: location, length: length)
    }

    private static func stringIndex(for position: TextPosition, in text: String) -> String.Index {
        let lineStart = lineStart(forZeroBasedLine: position.line, in: text)
        let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
        let startUTF8 = lineStart.samePosition(in: text.utf8) ?? text.utf8.startIndex
        let endUTF8 = lineEnd.samePosition(in: text.utf8) ?? text.utf8.endIndex
        let availableBytes = text.utf8.distance(from: startUTF8, to: endUTF8)
        var byteOffset = min(max(0, position.utf8Column), availableBytes)

        while byteOffset >= 0 {
            let candidate = text.utf8.index(startUTF8, offsetBy: byteOffset)
            if let index = candidate.samePosition(in: text) {
                return index
            }
            if byteOffset == 0 { break }
            byteOffset -= 1
        }
        return lineStart
    }

    private static func stringIndex(forUTF16Offset requestedOffset: Int, in text: String) -> String.Index {
        let utf16 = text.utf16
        var offset = min(max(0, requestedOffset), utf16.count)

        while offset >= 0 {
            let candidate = utf16.index(utf16.startIndex, offsetBy: offset)
            if let index = candidate.samePosition(in: text) {
                return index
            }
            if offset == 0 { break }
            offset -= 1
        }
        return text.startIndex
    }

    private static func lineStart(forZeroBasedLine requestedLine: Int, in text: String) -> String.Index {
        let targetLine = max(0, requestedLine)
        guard targetLine > 0 else { return text.startIndex }

        var currentLine = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "\n" {
                currentLine += 1
                let next = text.index(after: cursor)
                if currentLine == targetLine { return next }
            }
            cursor = text.index(after: cursor)
        }
        return text.endIndex
    }
}

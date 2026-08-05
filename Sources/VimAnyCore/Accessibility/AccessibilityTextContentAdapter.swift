import Foundation

struct AccessibilityWritePayload: Equatable {
    let text: String
    let selectionRange: NSRange
}

public struct AccessibilityTextReplacement: Equatable, Sendable {
    public let range: NSRange
    public let text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

struct ReferencePreservingCommitPlan: Equatable {
    /// Descending source ranges keep every remaining range valid as edits are
    /// applied to the original Accessibility value.
    let replacements: [AccessibilityTextReplacement]
    let finalSelectionRange: NSRange
    let expectedAccessibilityText: String
}

/// Translates application-specific Accessibility text into the plain-text
/// representation edited by Neovim. The adapter is deliberately kept below
/// the editor layer so AppKit and Neovim never need to know about rich editor
/// implementation details such as Cursor mention chips.
struct AccessibilityTextContentAdapter {
    let editableText: String
    let editableSelectionRange: NSRange

    private let kind: Kind

    var adaptedReferenceCount: Int {
        switch kind {
        case .identity:
            return 0
        case let .cursorReferences(references):
            return references.count
        }
    }

    var requiresReferencePreservingCommit: Bool {
        adaptedReferenceCount > 0
    }

    static func make(
        accessibilityText: String,
        selectionRange: NSRange,
        applicationName: String?
    ) -> AccessibilityTextContentAdapter {
        guard isCursor(applicationName) else {
            return identity(text: accessibilityText, selectionRange: selectionRange)
        }
        return cursor(accessibilityText: accessibilityText, selectionRange: selectionRange)
    }

    static func identity(
        text: String = "",
        selectionRange: NSRange = NSRange(location: 0, length: 0)
    ) -> AccessibilityTextContentAdapter {
        AccessibilityTextContentAdapter(
            editableText: text,
            editableSelectionRange: selectionRange,
            kind: .identity
        )
    }

    /// Cursor exposes a rich `@file` chip as three lines through AXValue:
    /// a private-use file icon, the visible label, and its private-use close
    /// icon. Present that implementation detail as ordinary `@label` text.
    private static func cursor(
        accessibilityText: String,
        selectionRange: NSRange
    ) -> AccessibilityTextContentAdapter {
        let decoded = CursorReferenceCodec.decode(
            accessibilityText,
            selectionRange: selectionRange
        )
        return AccessibilityTextContentAdapter(
            editableText: decoded.text,
            editableSelectionRange: decoded.selectionRange,
            kind: decoded.references.isEmpty ? .identity : .cursorReferences(decoded.references)
        )
    }

    /// Restores unchanged Cursor reference tokens for direct AX writes. If a
    /// user edits or removes `@label`, it remains ordinary text instead of
    /// accidentally being converted into a different structured reference.
    func directWritePayload(
        editableText: String,
        selectionRange: NSRange
    ) -> AccessibilityWritePayload {
        switch kind {
        case .identity:
            return AccessibilityWritePayload(text: editableText, selectionRange: selectionRange)
        case let .cursorReferences(references):
            return CursorReferenceCodec.encode(
                editableText,
                selectionRange: selectionRange,
                references: references
            )
        }
    }

    func normalizeReadBack(_ accessibilityText: String) -> String {
        switch kind {
        case .identity:
            return accessibilityText
        case .cursorReferences:
            return CursorReferenceCodec.decode(
                accessibilityText,
                selectionRange: NSRange(location: 0, length: 0)
            ).text
        }
    }

    /// Builds edits for only the plain-text gaps around Cursor reference
    /// nodes. The references must still exist, unmodified, and in their
    /// original order; otherwise a text-only client cannot safely preserve
    /// their identity and the caller must fail without replacing the field.
    func referencePreservingCommitPlan(
        currentAccessibilityText: String,
        editedText: String,
        selectionRange: NSRange
    ) -> ReferencePreservingCommitPlan? {
        guard case let .cursorReferences(capturedReferences) = kind else { return nil }

        let current = CursorReferenceCodec.decode(
            currentAccessibilityText,
            selectionRange: NSRange(location: 0, length: 0)
        )
        guard current.text == editableText,
              current.references.map(\.editableToken) == capturedReferences.map(\.editableToken),
              let editedReferenceRanges = CursorReferenceCodec.orderedReferenceRanges(
                  in: editedText,
                  references: current.references
              ) else {
            return nil
        }

        let currentEditableNSString = current.text as NSString
        let currentAccessibilityNSString = currentAccessibilityText as NSString
        let editedNSString = editedText as NSString
        var replacements: [AccessibilityTextReplacement] = []
        var expectedAccessibilityText = ""
        var currentEditableOffset = 0
        var currentAccessibilityOffset = 0
        var editedOffset = 0

        for (reference, editedReferenceRange) in zip(
            current.references,
            editedReferenceRanges
        ) {
            let currentEditableGap = NSRange(
                location: currentEditableOffset,
                length: reference.editableRange.location - currentEditableOffset
            )
            let currentAccessibilityGap = NSRange(
                location: currentAccessibilityOffset,
                length: reference.rawRange.location - currentAccessibilityOffset
            )
            let editedGap = NSRange(
                location: editedOffset,
                length: editedReferenceRange.location - editedOffset
            )
            let originalGapText = currentEditableNSString.substring(with: currentEditableGap)
            let editedGapText = editedNSString.substring(with: editedGap)
            if originalGapText != editedGapText {
                replacements.append(AccessibilityTextReplacement(
                    range: currentAccessibilityGap,
                    text: editedGapText
                ))
            }
            expectedAccessibilityText += editedGapText
            expectedAccessibilityText += reference.rawText
            currentEditableOffset = NSMaxRange(reference.editableRange)
            currentAccessibilityOffset = NSMaxRange(reference.rawRange)
            editedOffset = NSMaxRange(editedReferenceRange)
        }

        let originalTail = currentEditableNSString.substring(from: currentEditableOffset)
        let editedTail = editedNSString.substring(from: editedOffset)
        let rawTailRange = NSRange(
            location: currentAccessibilityOffset,
            length: currentAccessibilityNSString.length - currentAccessibilityOffset
        )
        if originalTail != editedTail {
            replacements.append(AccessibilityTextReplacement(
                range: rawTailRange,
                text: editedTail
            ))
        }
        expectedAccessibilityText += editedTail

        let finalPayload = CursorReferenceCodec.encode(
            editedText,
            selectionRange: selectionRange,
            references: current.references
        )
        guard finalPayload.text == expectedAccessibilityText else { return nil }

        return ReferencePreservingCommitPlan(
            replacements: replacements.sorted { lhs, rhs in
                lhs.range.location > rhs.range.location
            },
            finalSelectionRange: finalPayload.selectionRange,
            expectedAccessibilityText: expectedAccessibilityText
        )
    }

    /// Converts an editor selection back into the coordinate space currently
    /// exposed by the target. This matters when Cursor turns clean fallback
    /// text back into a rich reference before selection restoration.
    func selectionRange(
        inReadBack accessibilityText: String,
        editableText: String,
        editableSelectionRange: NSRange
    ) -> NSRange {
        switch kind {
        case .identity:
            return editableSelectionRange
        case .cursorReferences:
            let readBackAdapter = Self.cursor(
                accessibilityText: accessibilityText,
                selectionRange: NSRange(location: 0, length: 0)
            )
            guard readBackAdapter.editableText == editableText else {
                return editableSelectionRange
            }
            return readBackAdapter.directWritePayload(
                editableText: editableText,
                selectionRange: editableSelectionRange
            ).selectionRange
        }
    }

    private static func isCursor(_ applicationName: String?) -> Bool {
        guard let applicationName else { return false }
        return applicationName.range(
            of: "Cursor",
            options: [.anchored, .caseInsensitive]
        ) != nil
    }

    private enum Kind {
        case identity
        case cursorReferences([CursorReference])
    }
}

private struct CursorReference {
    let editableToken: String
    let rawText: String
    let labelRangeInRawText: NSRange
    let rawRange: NSRange
    let editableRange: NSRange
}

private enum CursorReferenceCodec {
    private static let closeIconScalar: UInt32 = 0xEA76

    struct Decoded {
        let text: String
        let selectionRange: NSRange
        let references: [CursorReference]
    }

    private struct Line {
        let text: String
        let contentRange: NSRange
    }

    private struct DecodingReplacement {
        let rawRange: NSRange
        let rawLabelRange: NSRange
        let editableToken: String
        var editableRange = NSRange(location: 0, length: 0)
    }

    private struct EncodingReplacement {
        let editableRange: NSRange
        let rawText: String
        let rawLabelRange: NSRange
        var rawRange = NSRange(location: 0, length: 0)
    }

    static func decode(_ rawText: String, selectionRange: NSRange) -> Decoded {
        let rawNSString = rawText as NSString
        let lines = lines(in: rawText)
        var replacements: [DecodingReplacement] = []
        var lineIndex = 0

        while lineIndex + 2 < lines.count {
            let iconLine = lines[lineIndex]
            let labelLine = lines[lineIndex + 1]
            let closeLine = lines[lineIndex + 2]

            guard let iconRange = privateUseIconRangeAtEnd(of: iconLine),
                  !labelLine.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let closeRange = closeIconRangeAtStart(of: closeLine) else {
                lineIndex += 1
                continue
            }

            let rawRange = NSRange(
                location: iconRange.location,
                length: NSMaxRange(closeRange) - iconRange.location
            )
            let editableToken = "@" + labelLine.text
            replacements.append(DecodingReplacement(
                rawRange: rawRange,
                rawLabelRange: labelLine.contentRange,
                editableToken: editableToken
            ))
            // The close icon for one chip and the file icon for the next can
            // share the same Accessibility line when references are inline.
            lineIndex += 2
        }

        guard !replacements.isEmpty else {
            return Decoded(text: rawText, selectionRange: selectionRange, references: [])
        }

        var editableText = ""
        var sourceOffset = 0
        for index in replacements.indices {
            let replacement = replacements[index]
            let prefixRange = NSRange(
                location: sourceOffset,
                length: replacement.rawRange.location - sourceOffset
            )
            editableText += rawNSString.substring(with: prefixRange)
            let editableLocation = (editableText as NSString).length
            editableText += replacement.editableToken
            replacements[index].editableRange = NSRange(
                location: editableLocation,
                length: (replacement.editableToken as NSString).length
            )
            sourceOffset = NSMaxRange(replacement.rawRange)
        }
        editableText += rawNSString.substring(from: sourceOffset)

        return Decoded(
            text: editableText,
            selectionRange: mapDecodedRange(
                selectionRange,
                rawLength: rawNSString.length,
                editableLength: (editableText as NSString).length,
                replacements: replacements
            ),
            references: replacements.map { replacement in
                CursorReference(
                    editableToken: replacement.editableToken,
                    rawText: rawNSString.substring(with: replacement.rawRange),
                    labelRangeInRawText: NSRange(
                        location: replacement.rawLabelRange.location
                            - replacement.rawRange.location,
                        length: replacement.rawLabelRange.length
                    ),
                    rawRange: replacement.rawRange,
                    editableRange: replacement.editableRange
                )
            }
        )
    }

    static func orderedReferenceRanges(
        in editableText: String,
        references: [CursorReference]
    ) -> [NSRange]? {
        let text = editableText as NSString
        var ranges: [NSRange] = []
        var searchOffset = 0
        for reference in references {
            guard let range = rangeOfUnmodifiedToken(
                reference.editableToken,
                in: text,
                startingAt: searchOffset
            ) else {
                return nil
            }
            ranges.append(range)
            searchOffset = NSMaxRange(range)
        }
        return ranges
    }

    static func encode(
        _ editableText: String,
        selectionRange: NSRange,
        references: [CursorReference]
    ) -> AccessibilityWritePayload {
        let editableNSString = editableText as NSString
        var replacements: [EncodingReplacement] = []
        var searchOffset = 0
        var remainingReferences = Array(references.enumerated())

        while searchOffset <= editableNSString.length, !remainingReferences.isEmpty {
            let candidates = remainingReferences.compactMap { indexedReference -> (Int, CursorReference, NSRange)? in
                let (index, reference) = indexedReference
                guard let range = rangeOfUnmodifiedToken(
                    reference.editableToken,
                    in: editableNSString,
                    startingAt: searchOffset
                ) else {
                    return nil
                }
                return (index, reference, range)
            }
            guard let match = candidates.min(by: { lhs, rhs in
                if lhs.2.location != rhs.2.location { return lhs.2.location < rhs.2.location }
                return lhs.2.length > rhs.2.length
            }) else { break }
            let (_, reference, tokenRange) = match
            replacements.append(EncodingReplacement(
                editableRange: tokenRange,
                rawText: reference.rawText,
                rawLabelRange: reference.labelRangeInRawText
            ))
            remainingReferences.removeAll { $0.offset == match.0 }
            searchOffset = NSMaxRange(tokenRange)
        }

        guard !replacements.isEmpty else {
            return AccessibilityWritePayload(
                text: editableText,
                selectionRange: selectionRange
            )
        }

        var rawText = ""
        var sourceOffset = 0
        for index in replacements.indices {
            let replacement = replacements[index]
            let prefixRange = NSRange(
                location: sourceOffset,
                length: replacement.editableRange.location - sourceOffset
            )
            rawText += editableNSString.substring(with: prefixRange)
            let rawLocation = (rawText as NSString).length
            rawText += replacement.rawText
            replacements[index].rawRange = NSRange(
                location: rawLocation,
                length: (replacement.rawText as NSString).length
            )
            sourceOffset = NSMaxRange(replacement.editableRange)
        }
        rawText += editableNSString.substring(from: sourceOffset)

        return AccessibilityWritePayload(
            text: rawText,
            selectionRange: mapEncodedRange(
                selectionRange,
                editableLength: editableNSString.length,
                rawLength: (rawText as NSString).length,
                replacements: replacements
            )
        )
    }

    private static func rangeOfUnmodifiedToken(
        _ token: String,
        in text: NSString,
        startingAt requestedOffset: Int
    ) -> NSRange? {
        var searchOffset = min(max(0, requestedOffset), text.length)
        while searchOffset <= text.length {
            let candidate = text.range(
                of: token,
                options: [],
                range: NSRange(location: searchOffset, length: text.length - searchOffset)
            )
            guard candidate.location != NSNotFound else { return nil }

            let candidateEnd = NSMaxRange(candidate)
            let followingIsBoundary = candidateEnd == text.length
                || isTokenBoundary(text.character(at: candidateEnd))
            if followingIsBoundary {
                return candidate
            }
            searchOffset = candidate.location + 1
        }
        return nil
    }

    private static func isTokenBoundary(_ utf16CodeUnit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(utf16CodeUnit) else { return false }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        return ".,;:!?()[]{}<>\"'`".unicodeScalars.contains(scalar)
    }

    private static func lines(in text: String) -> [Line] {
        let string = text as NSString
        var result: [Line] = []
        var lineStart = 0

        while lineStart <= string.length {
            let remainder = NSRange(
                location: lineStart,
                length: string.length - lineStart
            )
            let newline = string.range(of: "\n", options: [], range: remainder)
            let lineEnd = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: lineStart, length: lineEnd - lineStart)
            result.append(Line(text: string.substring(with: range), contentRange: range))

            guard newline.location != NSNotFound else { break }
            lineStart = NSMaxRange(newline)
        }
        return result
    }

    private static func privateUseIconRangeAtEnd(of line: Line) -> NSRange? {
        guard let scalar = line.text.unicodeScalars.last,
              scalar.value != closeIconScalar,
              isPrivateUse(scalar.value) else {
            return nil
        }
        let marker = String(scalar)
        let localRange = (line.text as NSString).range(of: marker, options: .backwards)
        guard localRange.location != NSNotFound,
              NSMaxRange(localRange) == line.contentRange.length else {
            return nil
        }
        return NSRange(
            location: line.contentRange.location + localRange.location,
            length: localRange.length
        )
    }

    private static func closeIconRangeAtStart(of line: Line) -> NSRange? {
        guard let scalar = line.text.unicodeScalars.first,
              scalar.value == closeIconScalar else {
            return nil
        }
        let length = (String(scalar) as NSString).length
        return NSRange(location: line.contentRange.location, length: length)
    }

    private static func isPrivateUse(_ value: UInt32) -> Bool {
        return (0xE000...0xF8FF).contains(value)
            || (0xF0000...0xFFFFD).contains(value)
            || (0x100000...0x10FFFD).contains(value)
    }

    private static func mapDecodedRange(
        _ range: NSRange,
        rawLength: Int,
        editableLength: Int,
        replacements: [DecodingReplacement]
    ) -> NSRange {
        guard range.location != NSNotFound else { return range }
        let start = min(max(0, range.location), rawLength)
        let requestedEnd = range.location > Int.max - max(0, range.length)
            ? rawLength
            : range.location + max(0, range.length)
        let end = min(max(start, requestedEnd), rawLength)
        let mappedStart = mapDecodedOffset(start, replacements: replacements)
        let mappedEnd = mapDecodedOffset(end, replacements: replacements)
        let location = min(max(0, mappedStart), editableLength)
        let upperBound = min(max(location, mappedEnd), editableLength)
        return NSRange(location: location, length: upperBound - location)
    }

    private static func mapDecodedOffset(
        _ offset: Int,
        replacements: [DecodingReplacement]
    ) -> Int {
        var delta = 0
        for replacement in replacements {
            guard offset >= replacement.rawRange.location else { break }
            let rawEnd = NSMaxRange(replacement.rawRange)
            if offset <= rawEnd {
                if offset == replacement.rawRange.location {
                    return replacement.editableRange.location
                }
                if offset <= replacement.rawLabelRange.location {
                    return replacement.editableRange.location + 1
                }
                if offset < NSMaxRange(replacement.rawLabelRange) {
                    return replacement.editableRange.location + 1
                        + offset - replacement.rawLabelRange.location
                }
                return NSMaxRange(replacement.editableRange)
            }
            delta += replacement.editableRange.length - replacement.rawRange.length
        }
        return offset + delta
    }

    private static func mapEncodedRange(
        _ range: NSRange,
        editableLength: Int,
        rawLength: Int,
        replacements: [EncodingReplacement]
    ) -> NSRange {
        guard range.location != NSNotFound else { return range }
        let start = min(max(0, range.location), editableLength)
        let requestedEnd = range.location > Int.max - max(0, range.length)
            ? editableLength
            : range.location + max(0, range.length)
        let end = min(max(start, requestedEnd), editableLength)
        let mappedStart = mapEncodedOffset(start, replacements: replacements)
        let mappedEnd = mapEncodedOffset(end, replacements: replacements)
        let location = min(max(0, mappedStart), rawLength)
        let upperBound = min(max(location, mappedEnd), rawLength)
        return NSRange(location: location, length: upperBound - location)
    }

    private static func mapEncodedOffset(
        _ offset: Int,
        replacements: [EncodingReplacement]
    ) -> Int {
        var delta = 0
        for replacement in replacements {
            guard offset >= replacement.editableRange.location else { break }
            let editableEnd = NSMaxRange(replacement.editableRange)
            if offset <= editableEnd {
                if offset == replacement.editableRange.location {
                    return replacement.rawRange.location
                }
                if offset == editableEnd {
                    return NSMaxRange(replacement.rawRange)
                }
                let labelOffset = offset - replacement.editableRange.location - 1
                return replacement.rawRange.location
                    + replacement.rawLabelRange.location
                    + max(0, labelOffset)
            }
            delta += replacement.rawRange.length - replacement.editableRange.length
        }
        return offset + delta
    }
}

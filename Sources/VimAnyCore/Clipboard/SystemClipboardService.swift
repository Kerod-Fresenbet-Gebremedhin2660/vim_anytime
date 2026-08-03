import AppKit
import Foundation

public struct PasteboardItemArchive: Sendable {
    public let values: [(type: String, data: Data)]

    public init(values: [(type: String, data: Data)]) {
        self.values = values
    }
}

public struct PasteboardArchive: Sendable {
    public let items: [PasteboardItemArchive]
    public let intentionalRevision: UInt64

    public init(items: [PasteboardItemArchive], intentionalRevision: UInt64) {
        self.items = items
        self.intentionalRevision = intentionalRevision
    }
}

/// Owns user-visible clipboard operations caused by Vim editing commands.
/// Temporary clipboard use for AX fallback deliberately goes through separate APIs.
public final class SystemClipboardService: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private var intentionalRevisionStorage: UInt64 = 0

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var intentionalRevision: UInt64 {
        onMain { self.intentionalRevisionStorage }
    }

    public func readText() -> String? {
        onMain { self.pasteboard.string(forType: .string) }
    }

    public func writeTextIntentionally(_ text: String) {
        onMain {
            self.intentionalRevisionStorage &+= 1
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
        }
    }

    public func writeFromVim(lines: [String], registerType: String) {
        let text: String
        if registerType.first == "V" {
            var normalizedLines = lines
            // Neovim's clipboard provider includes an empty sentinel after linewise yanks.
            // Preserve blank lines, but do not turn that sentinel into a second newline.
            if normalizedLines.count > 1, normalizedLines.last == "" {
                normalizedLines.removeLast()
            }
            text = normalizedLines.joined(separator: "\n") + "\n"
        } else {
            text = lines.joined(separator: "\n")
        }
        writeTextIntentionally(text)
    }

    public func readForVim() -> (lines: [String], registerType: String) {
        let text = readText() ?? ""
        let linewise = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if linewise, lines.last == "" {
            lines.removeLast()
        }
        if lines.isEmpty { lines = [""] }
        return (lines, linewise ? "V" : "v")
    }

    public func archive() -> PasteboardArchive {
        onMain {
            let items = (self.pasteboard.pasteboardItems ?? []).map { item in
                let values = item.types.compactMap { type -> (type: String, data: Data)? in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type.rawValue, data)
                }
                return PasteboardItemArchive(values: values)
            }
            return PasteboardArchive(items: items, intentionalRevision: self.intentionalRevisionStorage)
        }
    }

    /// Installs replacement text without marking it as a user-visible Vim clipboard action.
    /// Returns the pasteboard change count that must still match before restoration.
    public func installTemporaryText(_ text: String) -> Int {
        onMain {
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
            return self.pasteboard.changeCount
        }
    }

    @discardableResult
    public func restoreTemporaryArchive(
        _ archive: PasteboardArchive,
        expectedChangeCount: Int
    ) -> Bool {
        onMain {
            guard self.pasteboard.changeCount == expectedChangeCount,
                  self.intentionalRevisionStorage == archive.intentionalRevision else {
                return false
            }

            let restoredItems: [NSPasteboardItem] = archive.items.map { archived in
                let item = NSPasteboardItem()
                for value in archived.values {
                    item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type))
                }
                return item
            }
            self.pasteboard.clearContents()
            if !restoredItems.isEmpty {
                self.pasteboard.writeObjects(restoredItems)
            }
            return true
        }
    }

    private func onMain<T>(_ operation: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return operation()
        }
        return DispatchQueue.main.sync(execute: operation)
    }
}

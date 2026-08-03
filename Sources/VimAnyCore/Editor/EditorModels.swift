import Foundation

public struct TextPosition: Equatable, Hashable, Sendable {
    /// Zero-based buffer line.
    public var line: Int

    /// Zero-based UTF-8 byte column, matching Neovim's window cursor API.
    public var utf8Column: Int

    public init(line: Int, utf8Column: Int) {
        self.line = max(0, line)
        self.utf8Column = max(0, utf8Column)
    }
}

public struct EditorSelection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case caret
        case character
        case line
    }

    public var anchor: TextPosition
    public var head: TextPosition
    public var kind: Kind

    public init(anchor: TextPosition, head: TextPosition, kind: Kind) {
        self.anchor = anchor
        self.head = head
        self.kind = kind
    }

    public static func caret(at position: TextPosition) -> EditorSelection {
        EditorSelection(anchor: position, head: position, kind: .caret)
    }
}

public enum VimMode: Equatable, Sendable {
    case normal
    case insert
    case replace
    case visual
    case visualLine
    case operatorPending
    case commandLine
    case unknown(String)

    public var displayName: String {
        switch self {
        case .normal, .operatorPending, .commandLine:
            return "NORMAL"
        case .insert:
            return "INSERT"
        case .replace:
            return "REPLACE"
        case .visual:
            return "VISUAL"
        case .visualLine:
            return "V-LINE"
        case .unknown(let name):
            return name.uppercased()
        }
    }

    public var acceptsCommittedText: Bool {
        self == .insert || self == .replace
    }

    public var isNormalLike: Bool {
        switch self {
        case .normal, .operatorPending:
            return true
        default:
            return false
        }
    }
}

public struct VimKey: Equatable, Sendable {
    public let notation: String

    public init(_ notation: String) {
        self.notation = notation
    }
}

public struct EditorSnapshot: Equatable, Sendable {
    public let text: String
    public let cursor: TextPosition
    public let selection: EditorSelection?
    public let mode: VimMode
    public let message: String?
    public let pendingOperator: String?
    public let pendingCount: Int?
    public let command: String?

    public init(
        text: String,
        cursor: TextPosition,
        selection: EditorSelection?,
        mode: VimMode,
        message: String? = nil,
        pendingOperator: String? = nil,
        pendingCount: Int? = nil,
        command: String? = nil
    ) {
        self.text = text
        self.cursor = cursor
        self.selection = selection
        self.mode = mode
        self.message = message
        self.pendingOperator = pendingOperator
        self.pendingCount = pendingCount
        self.command = command
    }
}

public enum SafeExCommand: Equatable, Sendable {
    case write
    case writeAndClose
    case cancel
    case undo
    case redo
    case clearSearchHighlight
}

public enum EditorApplicationCommand: Equatable, Sendable {
    case commitAndClose
    case commit
    case cancel
}

public protocol NvimEditingEngine: Sendable {
    func start() async throws
    func load(text: String, selection: EditorSelection) async throws
    func sendKey(_ key: VimKey) async throws
    func insertText(_ text: String) async throws
    func snapshot() async throws -> EditorSnapshot
    func execute(_ command: SafeExCommand) async throws
    func setNativeSelection(_ selection: EditorSelection) async throws
    func reset() async throws
    func stop() async
}


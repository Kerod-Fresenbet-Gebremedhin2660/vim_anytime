import Foundation

@MainActor
public final class EditorViewModel {
    public var onSnapshot: ((EditorSnapshot) -> Void)?
    public var onApplicationCommand: ((EditorApplicationCommand) -> Void)?

    public private(set) var currentSnapshot: EditorSnapshot?
    public private(set) var exCommandText: String?
    private let engine: NvimEditingEngine
    private var actionTail: Task<Void, Never>?

    public init(engine: NvimEditingEngine) {
        self.engine = engine
    }

    public func load(text: String, selection: EditorSelection) async throws {
        if let actionTail { await actionTail.value }
        try await engine.start()
        try await engine.load(text: text, selection: selection)
        let snapshot = try await engine.snapshot()
        publish(snapshot)
    }

    public func handle(_ action: TranslatedKeyAction) {
        switch action {
        case .application(let command):
            onApplicationCommand?(command)
        case .vim(let key):
            enqueue { [engine] in
                try await engine.sendKey(key)
            }
        case .useNativeTextInput, .ignored:
            break
        case .beginExCommand:
            exCommandText = ""
            publishOverlay()
        case .appendExText(let text):
            exCommandText?.append(contentsOf: text)
            publishOverlay()
        case .deleteExCharacter:
            guard var command = exCommandText else { return }
            if !command.isEmpty { command.removeLast() }
            exCommandText = command
            publishOverlay()
        case .cancelExCommand:
            exCommandText = nil
            publishOverlay()
        case .submitExCommand:
            submitExCommand()
        }
    }

    public func insertCommittedText(_ text: String) {
        enqueue { [engine] in
            try await engine.insertText(text)
        }
    }

    public func setNativeSelection(_ selection: EditorSelection) {
        enqueue { [engine] in
            try await engine.setNativeSelection(selection)
        }
    }

    public func snapshotForCommit() async throws -> EditorSnapshot {
        if let actionTail { await actionTail.value }
        let snapshot = try await engine.snapshot()
        publish(snapshot)
        return snapshot
    }

    public func reset() async {
        if let actionTail { await actionTail.value }
        try? await engine.reset()
        currentSnapshot = nil
        exCommandText = nil
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = actionTail
        actionTail = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            do {
                try await operation()
                let snapshot = try await self.engine.snapshot()
                self.publish(snapshot)
            } catch {
                self.publishError(error.localizedDescription)
            }
        }
    }

    private func submitExCommand() {
        guard let rawCommand = exCommandText else { return }
        exCommandText = nil
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        switch command {
        case "":
            publishOverlay()
        case "w":
            onApplicationCommand?(.commit)
        case "wq", "x":
            onApplicationCommand?(.commitAndClose)
        case "q", "q!":
            onApplicationCommand?(.cancel)
        case "u", "undo":
            enqueue { [engine] in try await engine.execute(.undo) }
        case "redo":
            enqueue { [engine] in try await engine.execute(.redo) }
        case "noh", "nohl", "nohlsearch":
            enqueue { [engine] in try await engine.execute(.clearSearchHighlight) }
        default:
            publishError("E492: Not an allowed VimAny command: \(command)")
        }
    }

    private func publish(_ snapshot: EditorSnapshot) {
        currentSnapshot = snapshot
        publishOverlay()
    }

    private func publishOverlay() {
        guard let snapshot = currentSnapshot else { return }
        if let exCommandText {
            onSnapshot?(EditorSnapshot(
                text: snapshot.text,
                cursor: snapshot.cursor,
                selection: snapshot.selection,
                mode: .commandLine,
                message: nil,
                pendingOperator: snapshot.pendingOperator,
                pendingCount: snapshot.pendingCount,
                command: ":\(exCommandText)"
            ))
        } else {
            onSnapshot?(snapshot)
        }
    }

    private func publishError(_ message: String) {
        guard let snapshot = currentSnapshot else { return }
        let errorSnapshot = EditorSnapshot(
            text: snapshot.text,
            cursor: snapshot.cursor,
            selection: snapshot.selection,
            mode: snapshot.mode,
            message: message,
            pendingOperator: snapshot.pendingOperator,
            pendingCount: snapshot.pendingCount,
            command: snapshot.command
        )
        currentSnapshot = errorSnapshot
        onSnapshot?(errorSnapshot)
    }
}

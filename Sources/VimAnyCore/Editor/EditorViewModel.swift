import Foundation

@MainActor
public final class EditorViewModel {
    public var onSnapshot: ((EditorSnapshot) -> Void)?
    public var onApplicationCommand: ((EditorApplicationCommand) -> Void)?

    public private(set) var currentSnapshot: EditorSnapshot?
    public private(set) var exCommandText: String?
    private let engine: NvimEditingEngine
    private let logger = DiagnosticLogger.shared
    private var actionTail: Task<Void, Never>?

    public init(engine: NvimEditingEngine) {
        self.engine = engine
    }

    public func load(text: String, selection: EditorSelection) async throws {
        logger.info(
            "Editor",
            "load requested utf16Length=\(text.utf16.count) "
                + "selectionKind=\(String(describing: selection.kind))"
        )
        if let actionTail { await actionTail.value }
        try await engine.start()
        try await engine.load(text: text, selection: selection)
        let snapshot = try await engine.snapshot()
        publish(snapshot)
        logger.info("Editor", "load completed mode=\(snapshot.mode.displayName)")
    }

    public func handle(_ action: TranslatedKeyAction) {
        switch action {
        case .application(let command):
            logger.info("Editor", "application command=\(String(describing: command))")
            onApplicationCommand?(command)
        case .vim(let key):
            enqueue { [engine] in
                try await engine.sendKey(key)
            }
        case .useNativeTextInput, .ignored:
            break
        case .beginExCommand:
            logger.info("Editor", "native Ex input started")
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
            logger.info("Editor", "native Ex input canceled")
            exCommandText = nil
            publishOverlay()
        case .submitExCommand:
            submitExCommand()
        }
    }

    public func insertCommittedText(_ text: String) {
        logger.debug(
            "Editor",
            "native committed text utf16Length=\(text.utf16.count) utf8Length=\(text.utf8.count)"
        )
        enqueue { [engine] in
            try await engine.insertText(text)
        }
    }

    public func setNativeSelection(_ selection: EditorSelection) {
        logger.debug(
            "Editor",
            "native selection changed kind=\(String(describing: selection.kind)) "
                + "anchorLine=\(selection.anchor.line) headLine=\(selection.head.line)"
        )
        enqueue { [engine] in
            try await engine.setNativeSelection(selection)
        }
    }

    public func snapshotForCommit() async throws -> EditorSnapshot {
        logger.debug("Editor", "commit snapshot requested")
        if let actionTail { await actionTail.value }
        let snapshot = try await engine.snapshot()
        publish(snapshot)
        return snapshot
    }

    public func reset() async {
        logger.info("Editor", "reset requested")
        if let actionTail { await actionTail.value }
        do {
            try await engine.reset()
        } catch {
            logger.error("Editor", error: error, context: "engine reset failed")
        }
        currentSnapshot = nil
        exCommandText = nil
        logger.info("Editor", "reset completed")
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
                self.logger.error("Editor", error: error, context: "queued engine operation failed")
                self.publishError(error.localizedDescription)
            }
        }
    }

    private func submitExCommand() {
        guard let rawCommand = exCommandText else { return }
        exCommandText = nil
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Editor", "native Ex input submitted characterCount=\(command.count)")

        switch command {
        case "":
            publishOverlay()
        case "w":
            logger.info("Editor", "allowed Ex command=write")
            onApplicationCommand?(.commit)
        case "wq", "x":
            logger.info("Editor", "allowed Ex command=writeAndClose")
            onApplicationCommand?(.commitAndClose)
        case "q", "q!":
            logger.info("Editor", "allowed Ex command=cancel")
            onApplicationCommand?(.cancel)
        case "u", "undo":
            logger.info("Editor", "allowed Ex command=undo")
            enqueue { [engine] in try await engine.execute(.undo) }
        case "redo":
            logger.info("Editor", "allowed Ex command=redo")
            enqueue { [engine] in try await engine.execute(.redo) }
        case "noh", "nohl", "nohlsearch":
            logger.info("Editor", "allowed Ex command=clearSearchHighlight")
            enqueue { [engine] in try await engine.execute(.clearSearchHighlight) }
        default:
            logger.warning("Editor", "rejected Ex command characterCount=\(command.count)")
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

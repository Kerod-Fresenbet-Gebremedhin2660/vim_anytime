import Foundation

public enum NvimHostError: Error, LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case configurationFailed(stage: String, message: String)
    case invalidResponse(method: String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Neovim was not found. Install nvim or set VIMANY_NVIM_PATH to its executable."
        case .launchFailed(let message):
            return "Neovim could not be launched: \(message)"
        case .configurationFailed(let stage, let message):
            return "Neovim configuration failed during \(stage): \(message)"
        case .invalidResponse(let method):
            return "Neovim returned an invalid response for \(method)."
        case .notRunning:
            return "The embedded Neovim process is not running."
        }
    }
}

public actor NvimHost: NvimEditingEngine {
    private let logger = DiagnosticLogger.shared
    private let clipboard: SystemClipboardService
    private let executableURL: URL?
    private var process: Process?
    private var rpcClient: MessagePackRPCClient?
    private var standardInputPipe: Pipe?
    private var standardOutputPipe: Pipe?
    private var standardErrorPipe: Pipe?
    private var stopping = false
    private var recoverySnapshot: EditorSnapshot?
    private var pendingInputTokens: [String] = []

    public init(
        clipboard: SystemClipboardService,
        executableURL: URL? = nil
    ) {
        self.clipboard = clipboard
        self.executableURL = executableURL
    }

    public func start() async throws {
        logger.info("Neovim", "start requested")
        stopping = false
        do {
            try await ensureRunning(recovering: true)
            logger.info("Neovim", "start completed")
        } catch {
            logger.error("Neovim", error: error, context: "start failed")
            throw error
        }
    }

    public func load(text: String, selection: EditorSelection) async throws {
        logger.info(
            "Neovim",
            "buffer load utf16Length=\(text.utf16.count) utf8Length=\(text.utf8.count) "
                + "selection=\(Self.describe(selection))"
        )
        pendingInputTokens.removeAll()
        try await withRestart {
            try await self.loadInternal(text: text, selection: selection, desiredMode: .normal)
        }
        recoverySnapshot = try await snapshot()
    }

    public func sendKey(_ key: VimKey) async throws {
        logger.debug("Neovim", "key input \(Self.describe(key))")
        try await withRestart {
            try await self.inputNotation(key.notation, tracksPendingInput: true)
        }
    }

    public func insertText(_ text: String) async throws {
        guard !text.isEmpty else { return }
        logger.debug(
            "Neovim",
            "committed text input utf16Length=\(text.utf16.count) utf8Length=\(text.utf8.count)"
        )
        try await withRestart {
            _ = try await self.rawRequest(
                "nvim_paste",
                [.string(text), .bool(false), .int(-1)]
            )
            _ = try await self.rawRequest("nvim_eval", [.string("0")])
        }
    }

    public func snapshot() async throws -> EditorSnapshot {
        let modeState = try await withRestart {
            try await self.currentModeState()
        }
        if shouldReturnPendingSnapshot(for: modeState) {
            let snapshot = makePendingSnapshot(modeState: modeState)
            logger.debug(
                "Neovim",
                "pending snapshot mode=\(snapshot.mode.displayName) "
                    + "tokenCount=\(pendingInputTokens.count) blocking=\(modeState.isBlocking)"
            )
            return snapshot
        }

        let result = try await withRestart {
            try await self.rawRequest("nvim_exec_lua", [
                .string(Self.snapshotLua),
                .array([]),
            ])
        }
        let snapshot = try decodeSnapshot(result)
        pendingInputTokens.removeAll()
        recoverySnapshot = snapshot
        logger.debug(
            "Neovim",
            "snapshot mode=\(snapshot.mode.displayName) cursor=\(Self.describe(snapshot.cursor)) "
                + "selection=\(snapshot.selection.map(Self.describe) ?? "none") "
                + "utf16Length=\(snapshot.text.utf16.count) "
                + "messagePresent=\(snapshot.message != nil)"
        )
        return snapshot
    }

    public func execute(_ command: SafeExCommand) async throws {
        logger.info("Neovim", "safe command=\(String(describing: command))")
        switch command {
        case .undo:
            try await sendKey(VimKey("u"))
        case .redo:
            try await sendKey(VimKey("<C-r>"))
        case .clearSearchHighlight:
            try await withRestart {
                _ = try await self.rawRequest("nvim_exec_lua", [
                    .string("vim.cmd('nohlsearch')"),
                    .array([]),
                ])
            }
        case .write, .writeAndClose, .cancel:
            // These commands belong to the native field session, not to the scratch buffer.
            break
        }
    }

    public func setNativeSelection(_ selection: EditorSelection) async throws {
        logger.debug("Neovim", "native selection update \(Self.describe(selection))")
        try await withRestart {
            try await self.applySelection(selection)
        }
    }

    public func reset() async throws {
        logger.info("Neovim", "buffer reset requested")
        pendingInputTokens.removeAll()
        try await withRestart {
            try await self.loadInternal(
                text: "",
                selection: .caret(at: TextPosition(line: 0, utf8Column: 0)),
                desiredMode: .normal
            )
        }
        recoverySnapshot = nil
        pendingInputTokens.removeAll()
        logger.info("Neovim", "buffer reset completed")
    }

    public func stop() async {
        logger.info("Neovim", "stop requested")
        stopping = true
        let oldClient = rpcClient
        let oldProcess = process
        rpcClient = nil
        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe = nil
        pendingInputTokens.removeAll()
        oldClient?.close(reason: "VimAny is stopping")
        oldProcess?.terminationHandler = nil
        if oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }
        logger.info("Neovim", "stop completed")
    }

    public func isProcessRunning() -> Bool {
        process?.isRunning == true
    }

    func terminateEmbeddedProcessForTesting() {
        process?.terminate()
    }

    private func ensureRunning(recovering: Bool) async throws {
        if process?.isRunning == true, rpcClient != nil {
            logger.debug("Neovim", "existing process is healthy")
            return
        }
        logger.info("Neovim", "launch required recovering=\(recovering)")
        try launch()
        try await configure()
        if recovering, let recoverySnapshot {
            logger.info(
                "Neovim",
                "recovering buffer utf16Length=\(recoverySnapshot.text.utf16.count) "
                    + "mode=\(recoverySnapshot.mode.displayName)"
            )
            let selection = recoverySnapshot.selection
                ?? .caret(at: recoverySnapshot.cursor)
            try await loadInternal(
                text: recoverySnapshot.text,
                selection: selection,
                desiredMode: recoverySnapshot.mode
            )
        }
    }

    private func launch() throws {
        let url = executableURL ?? Self.locateNvimExecutable()
        guard let url else {
            logger.error("Neovim", "executable lookup failed")
            throw NvimHostError.executableNotFound
        }
        logger.info("Neovim", "launching executable=\(url.path)")

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = url
        process.arguments = ["--embed", "--headless", "--clean", "-i", "NONE"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["NVIM_APPNAME"] = "vimany-embedded"
        process.environment = environment

        let client = MessagePackRPCClient(
            input: outputPipe.fileHandleForReading,
            output: inputPipe.fileHandleForWriting
        )
        installClipboardHandlers(on: client)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let message = String(data: data, encoding: .utf8)
                ?? "non-UTF8 stderr bytes=\(data.count)"
            DiagnosticLogger.shared.warning("Neovim stderr", message)
        }
        process.terminationHandler = { [weak client] process in
            DiagnosticLogger.shared.warning(
                "Neovim",
                "process exited status=\(process.terminationStatus) "
                    + "reason=\(String(describing: process.terminationReason))"
            )
            client?.close(reason: "Neovim exited with status \(process.terminationStatus)")
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            client.close(reason: error.localizedDescription)
            logger.error("Neovim", error: error, context: "Process.run failed")
            throw NvimHostError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.rpcClient = client
        self.standardInputPipe = inputPipe
        self.standardOutputPipe = outputPipe
        self.standardErrorPipe = errorPipe
        stopping = false
        logger.info("Neovim", "process launched pid=\(process.processIdentifier)")
    }

    private func configure() async throws {
        logger.info("Neovim", "deterministic configuration started")
        let apiInfo = try await rawRequest("nvim_get_api_info")
        guard let values = apiInfo.arrayValue,
              let channel = values.first?.intValue else {
            throw NvimHostError.invalidResponse(method: "nvim_get_api_info")
        }
        try await configureStep(name: "base options", source: Self.configurationLua, arguments: [])
        try await configureStep(
            name: "clipboard provider",
            source: Self.clipboardProviderLua,
            arguments: [.int(channel)]
        )
        try await configureStep(name: "clipboard option", source: "vim.o.clipboard = 'unnamedplus'", arguments: [])
        try await configureStep(name: "safety mappings", source: Self.safetyMappingsLua, arguments: [])
        logger.info("Neovim", "deterministic configuration completed channel=\(channel)")
    }

    private func configureStep(
        name: String,
        source: String,
        arguments: [MessagePackValue]
    ) async throws {
        logger.debug("Neovim", "configuration step started name=\(name)")
        do {
            _ = try await rawRequest("nvim_exec_lua", [
                .string(source),
                .array(arguments),
            ])
        } catch {
            logger.error("Neovim", error: error, context: "configuration step failed name=\(name)")
            throw NvimHostError.configurationFailed(stage: name, message: error.localizedDescription)
        }
        logger.debug("Neovim", "configuration step completed name=\(name)")
    }

    private func withRestart<T>(
        operation: () async throws -> T
    ) async throws -> T {
        do {
            try await ensureRunning(recovering: true)
            return try await operation()
        } catch {
            guard !stopping else { throw error }
            logger.warning(
                "Neovim",
                "operation failed; restarting embedded process error=\(error.localizedDescription)"
            )
            await tearDownForRestart()
            do {
                try await ensureRunning(recovering: false)
                if let recoverySnapshot {
                    try await loadInternal(
                        text: recoverySnapshot.text,
                        selection: recoverySnapshot.selection ?? .caret(at: recoverySnapshot.cursor),
                        desiredMode: recoverySnapshot.mode
                    )
                }
                let result = try await operation()
                logger.info("Neovim", "automatic restart and operation retry succeeded")
                return result
            } catch {
                logger.error("Neovim", error: error, context: "automatic restart or retry failed")
                throw error
            }
        }
    }

    private func tearDownForRestart() async {
        logger.info("Neovim", "tearing down process for restart")
        let oldClient = rpcClient
        let oldProcess = process
        rpcClient = nil
        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe = nil
        pendingInputTokens.removeAll()
        oldClient?.close(reason: "Restarting Neovim")
        oldProcess?.terminationHandler = nil
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
    }

    private func rawRequest(
        _ method: String,
        _ parameters: [MessagePackValue] = []
    ) async throws -> MessagePackValue {
        guard let rpcClient else { throw NvimHostError.notRunning }
        return try await rpcClient.request(method: method, parameters: parameters)
    }

    private static func describe(_ key: VimKey) -> String {
        if key.notation.hasPrefix("<"), key.notation.hasSuffix(">") {
            return "special=\(key.notation)"
        }
        return "printableCharacters=\(key.notation.count) utf8Length=\(key.notation.utf8.count)"
    }

    private static func describe(_ position: TextPosition) -> String {
        "line=\(position.line) utf8Column=\(position.utf8Column)"
    }

    private static func describe(_ selection: EditorSelection) -> String {
        "kind=\(String(describing: selection.kind)) "
            + "anchor={\(describe(selection.anchor))} head={\(describe(selection.head))}"
    }

    private func loadInternal(
        text: String,
        selection: EditorSelection,
        desiredMode: VimMode
    ) async throws {
        _ = try await rawRequest("nvim_exec_lua", [
            .string(Self.beforeLoadLua),
            .array([]),
        ])
        let lines = text.components(separatedBy: "\n").map(MessagePackValue.string)
        _ = try await rawRequest("nvim_buf_set_lines", [
            .int(0), .int(0), .int(-1), .bool(true), .array(lines),
        ])
        _ = try await rawRequest("nvim_exec_lua", [
            .string(Self.afterLoadLua),
            .array([]),
        ])
        try await applySelection(selection)

        switch desiredMode {
        case .insert:
            try await inputNotation("i", tracksPendingInput: false)
        case .replace:
            try await inputNotation("R", tracksPendingInput: false)
        default:
            break
        }
    }

    private func applySelection(_ selection: EditorSelection) async throws {
        try await inputNotation("<Esc><Esc>", tracksPendingInput: false)
        _ = try await rawRequest("nvim_win_set_cursor", [
            .int(0),
            .array([.int(Int64(selection.anchor.line + 1)), .int(Int64(selection.anchor.utf8Column))]),
        ])

        switch selection.kind {
        case .caret:
            break
        case .character:
            try await inputNotation("v", tracksPendingInput: false)
            _ = try await rawRequest("nvim_win_set_cursor", [
                .int(0),
                .array([.int(Int64(selection.head.line + 1)), .int(Int64(selection.head.utf8Column))]),
            ])
        case .line:
            try await inputNotation("V", tracksPendingInput: false)
            _ = try await rawRequest("nvim_win_set_cursor", [
                .int(0),
                .array([.int(Int64(selection.head.line + 1)), .int(Int64(selection.head.utf8Column))]),
            ])
        }
    }

    private func inputNotation(
        _ notation: String,
        tracksPendingInput: Bool = false
    ) async throws {
        // nvim_input translates key notation such as <BS> and <Left> itself.
        // Pre-expanding with nvim_replace_termcodes would return Neovim's
        // internal K_SPECIAL bytes over RPC, which are not valid UTF-8.
        _ = try await rawRequest("nvim_input", [.string(notation)])
        if tracksPendingInput {
            pendingInputTokens.append(contentsOf: Self.tokenize(notation))
        }
    }

    private struct ModeState {
        let rawMode: String
        let isBlocking: Bool
    }

    private func currentModeState() async throws -> ModeState {
        let value = try await rawRequest("nvim_get_mode")
        guard let rawMode = value["mode"]?.stringValue,
              let isBlocking = value["blocking"]?.boolValue else {
            throw NvimHostError.invalidResponse(method: "nvim_get_mode")
        }
        return ModeState(rawMode: rawMode, isBlocking: isBlocking)
    }

    private func shouldReturnPendingSnapshot(for modeState: ModeState) -> Bool {
        guard !pendingInputTokens.isEmpty else { return false }
        let mode = Self.mode(from: modeState.rawMode)
        if mode == .operatorPending || mode == .commandLine { return true }
        return Self.isSyntacticallyIncomplete(
            pendingInputTokens,
            startingIn: recoverySnapshot?.mode ?? .normal
        )
    }

    private func makePendingSnapshot(modeState: ModeState) -> EditorSnapshot {
        let fallbackPosition = TextPosition(line: 0, utf8Column: 0)
        let base = recoverySnapshot ?? EditorSnapshot(
            text: "",
            cursor: fallbackPosition,
            selection: nil,
            mode: .normal
        )
        let rawMode = Self.mode(from: modeState.rawMode)
        let operatorName = Self.pendingOperator(in: pendingInputTokens)
        let mode: VimMode
        if rawMode == .operatorPending || operatorName != nil {
            mode = .operatorPending
        } else if rawMode == .commandLine || Self.commandLineStart(in: pendingInputTokens) != nil {
            mode = .commandLine
        } else {
            mode = rawMode
        }

        return EditorSnapshot(
            text: base.text,
            cursor: base.cursor,
            selection: base.selection,
            mode: mode,
            message: nil,
            pendingOperator: operatorName,
            pendingCount: Self.pendingCount(in: pendingInputTokens),
            command: Self.pendingCommandLine(in: pendingInputTokens)
        )
    }

    private func decodeSnapshot(_ value: MessagePackValue) throws -> EditorSnapshot {
        guard let lineValues = value["lines"]?.arrayValue,
              let cursorValues = value["cursor"]?.arrayValue,
              cursorValues.count >= 2,
              let oneBasedLine = cursorValues[0].intValue,
              let byteColumn = cursorValues[1].intValue,
              let rawMode = value["mode"]?.stringValue else {
            throw NvimHostError.invalidResponse(method: "snapshot")
        }

        let text = lineValues.compactMap(\.stringValue).joined(separator: "\n")
        let cursor = TextPosition(
            line: max(0, Int(oneBasedLine) - 1),
            utf8Column: max(0, Int(byteColumn))
        )
        let mode = Self.mode(from: rawMode)
        var selection: EditorSelection?
        if let visual = value["visual"]?.arrayValue,
           visual.count >= 3,
           let line = visual[0].intValue,
           let column = visual[1].intValue,
           let kind = visual[2].stringValue {
            let anchor = TextPosition(line: Int(line), utf8Column: Int(column))
            selection = EditorSelection(
                anchor: anchor,
                head: cursor,
                kind: kind == "V" ? .line : .character
            )
        }

        let errorMessage = value["error"]?.stringValue
        let infoMessage = value["info"]?.stringValue
        let message = [errorMessage, infoMessage]
            .compactMap { item in item.flatMap { $0.isEmpty ? nil : $0 } }
            .first
        let pendingOperator = mode == .operatorPending
            ? value["operator"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            : nil
        let count = mode == .operatorPending
            ? value["count"]?.intValue.flatMap { $0 > 0 ? Int($0) : nil }
            : nil
        let command = value["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }

        return EditorSnapshot(
            text: text,
            cursor: cursor,
            selection: selection,
            mode: mode,
            message: message,
            pendingOperator: pendingOperator,
            pendingCount: count,
            command: command
        )
    }

    private func installClipboardHandlers(on client: MessagePackRPCClient) {
        let clipboard = self.clipboard
        client.setRequestHandler { method, parameters in
            switch method {
            case "vimany_clipboard_get":
                let contents = clipboard.readForVim()
                return .array([
                    .array(contents.lines.map(MessagePackValue.string)),
                    .string(contents.registerType),
                ])
            case "vimany_clipboard_set":
                Self.handleClipboardSet(parameters, clipboard: clipboard)
                return .null
            default:
                throw MessagePackRPCError.remote("Unsupported host RPC method: \(method)")
            }
        }
        client.setNotificationHandler { method, parameters in
            if method == "vimany_clipboard_set" {
                Self.handleClipboardSet(parameters, clipboard: clipboard)
            }
        }
    }

    private static func handleClipboardSet(
        _ parameters: [MessagePackValue],
        clipboard: SystemClipboardService
    ) {
        guard parameters.count >= 2,
              let lineValues = parameters[0].arrayValue,
              let registerType = parameters[1].stringValue else { return }
        clipboard.writeFromVim(
            lines: lineValues.compactMap(\.stringValue),
            registerType: registerType
        )
    }

    private static func tokenize(_ notation: String) -> [String] {
        var tokens: [String] = []
        var index = notation.startIndex
        while index < notation.endIndex {
            if notation[index] == "<",
               let closing = notation[index...].firstIndex(of: ">") {
                tokens.append(String(notation[index...closing]))
                index = notation.index(after: closing)
            } else {
                let next = notation.index(after: index)
                tokens.append(String(notation[index..<next]))
                index = next
            }
        }
        return tokens
    }

    private static func isSyntacticallyIncomplete(
        _ tokens: [String],
        startingIn mode: VimMode
    ) -> Bool {
        guard !tokens.isEmpty else { return false }
        if commandLineStart(in: tokens) != nil {
            return !isCommandLineTerminator(tokens.last)
        }
        if isCommandLineTerminator(tokens.last) { return false }

        var index = 0
        let hasLeadingCount = consumeCount(in: tokens, index: &index)
        if index == tokens.count { return hasLeadingCount }

        let token = tokens[index]
        if mode == .normal || mode == .operatorPending {
            if normalOperators.contains(token) {
                index += 1
                _ = consumeCount(in: tokens, index: &index)
                if index == tokens.count { return true }

                let motion = tokens[index]
                if textObjectPrefixes.contains(motion)
                    || motionPrefixes.contains(motion)
                    || characterArgumentCommands.contains(motion) {
                    return index + 1 == tokens.count
                }
                return false
            }
        }

        if motionPrefixes.contains(token) || characterArgumentCommands.contains(token) {
            return index + 1 == tokens.count
        }
        return false
    }

    @discardableResult
    private static func consumeCount(in tokens: [String], index: inout Int) -> Bool {
        guard index < tokens.count,
              tokens[index].count == 1,
              let first = tokens[index].first,
              first >= "1", first <= "9" else { return false }
        index += 1
        while index < tokens.count,
              tokens[index].count == 1,
              let digit = tokens[index].first,
              digit >= "0", digit <= "9" {
            index += 1
        }
        return true
    }

    private static func pendingOperator(in tokens: [String]) -> String? {
        var index = 0
        _ = consumeCount(in: tokens, index: &index)
        guard index < tokens.count else { return nil }
        if normalOperators.contains(tokens[index]) { return tokens[index] }
        if index + 1 < tokens.count,
           tokens[index] == "g",
           ["U", "u", "~"].contains(tokens[index + 1]) {
            return tokens[index] + tokens[index + 1]
        }
        return nil
    }

    private static func pendingCount(in tokens: [String]) -> Int? {
        var index = 0
        let leading = consumeCountValue(in: tokens, index: &index)
        var operatorCount: Int?
        if index < tokens.count, normalOperators.contains(tokens[index]) {
            index += 1
            operatorCount = consumeCountValue(in: tokens, index: &index)
        }
        switch (leading, operatorCount) {
        case (nil, nil): return nil
        case (let value?, nil), (nil, let value?): return value
        case (let first?, let second?):
            let result = first.multipliedReportingOverflow(by: second)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    private static func consumeCountValue(in tokens: [String], index: inout Int) -> Int? {
        let start = index
        guard consumeCount(in: tokens, index: &index) else { return nil }
        return Int(tokens[start..<index].joined())
    }

    private static func commandLineStart(in tokens: [String]) -> Int? {
        var index = 0
        _ = consumeCount(in: tokens, index: &index)
        if index < tokens.count, normalOperators.contains(tokens[index]) {
            index += 1
            _ = consumeCount(in: tokens, index: &index)
        }
        guard index < tokens.count,
              tokens[index] == "/" || tokens[index] == "?" else { return nil }
        return index
    }

    private static func pendingCommandLine(in tokens: [String]) -> String? {
        guard let start = commandLineStart(in: tokens),
              !isCommandLineTerminator(tokens.last) else { return nil }
        var command = tokens[start]
        for token in tokens.dropFirst(start + 1) {
            if token == "<BS>" || token == "<Del>" {
                if command.count > 1 { command.removeLast() }
            } else if token.count == 1 {
                command.append(token)
            }
        }
        return command
    }

    private static func isCommandLineTerminator(_ token: String?) -> Bool {
        token == "<CR>" || token == "<Esc>" || token == "<C-c>"
    }

    private static let normalOperators: Set<String> = ["d", "c", "y", ">", "<", "="]
    private static let textObjectPrefixes: Set<String> = ["i", "a"]
    private static let motionPrefixes: Set<String> = ["g", "z", "[", "]", "<C-w>"]
    private static let characterArgumentCommands: Set<String> = ["f", "F", "t", "T", "r"]

    private static func mode(from rawMode: String) -> VimMode {
        if rawMode == "v" || rawMode == "\u{16}" || rawMode.hasPrefix("vs") { return .visual }
        if rawMode == "V" || rawMode.hasPrefix("Vs") { return .visualLine }
        if rawMode.hasPrefix("no") { return .operatorPending }
        if rawMode.hasPrefix("i") { return .insert }
        if rawMode.hasPrefix("R") { return .replace }
        if rawMode.hasPrefix("c") { return .commandLine }
        if rawMode.hasPrefix("n") { return .normal }
        return .unknown(rawMode)
    }

    private static func locateNvimExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["VIMANY_NVIM_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/nvim" }
        }
        candidates += [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/nvim").path,
            "/opt/homebrew/bin/nvim",
            "/usr/local/bin/nvim",
            "/usr/bin/nvim",
        ]

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static let configurationLua = #"""
vim.g.vimany_configured = true
vim.o.loadplugins = false
vim.o.modeline = false
vim.o.exrc = false
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.undofile = false
vim.o.shada = ''
vim.o.mouse = ''
vim.o.hidden = true
vim.o.report = 9999
vim.o.shortmess = 'filnxtToOF'
vim.o.clipboard = ''
vim.o.backspace = 'indent,eol,start'
vim.bo.buftype = 'nofile'
vim.bo.bufhidden = 'hide'
vim.bo.swapfile = false
vim.bo.undofile = false
"""#

    private static let clipboardProviderLua = #"""
local channel = ...
vim.g.clipboard = {
  name = 'VimAny macOS clipboard',
  copy = {
    ['+'] = function(lines, regtype)
      vim.rpcnotify(channel, 'vimany_clipboard_set', lines, regtype)
    end,
    ['*'] = function(lines, regtype)
      vim.rpcnotify(channel, 'vimany_clipboard_set', lines, regtype)
    end,
  },
  paste = {
    ['+'] = function()
      return vim.rpcrequest(channel, 'vimany_clipboard_get')
    end,
    ['*'] = function()
      return vim.rpcrequest(channel, 'vimany_clipboard_get')
    end,
  },
  cache_enabled = 0,
}
"""#

    private static let safetyMappingsLua = #"""
local normal_blocked = { ':', 'q', '@', 'Q', 'Z', '!', 'm', "'", '`', '"', '<C-z>', 'K' }
for _, key in ipairs(normal_blocked) do
  vim.keymap.set('n', key, '<Nop>', { noremap = true, silent = true, nowait = true })
end
local visual_blocked = { ':', '@', 'Q', '!', '"', '<C-z>', 'K' }
for _, key in ipairs(visual_blocked) do
  vim.keymap.set('x', key, '<Nop>', { noremap = true, silent = true, nowait = true })
end
vim.keymap.set('n', 'gQ', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('n', 'gx', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('n', 'gf', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('n', 'gF', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('n', '<C-]>', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('n', '<C-^>', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('c', '<C-f>', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('c', '<C-r>', '<Nop>', { noremap = true, silent = true })
vim.keymap.set('c', [[<C-\>]], '<Nop>', { noremap = true, silent = true })
vim.keymap.set('i', '<C-r>', '<Nop>', { noremap = true, silent = true })
"""#

    private static let beforeLoadLua = #"""
vim.api.nvim_input(vim.api.nvim_replace_termcodes('<Esc><Esc>', true, false, true))
vim.bo.undolevels = -1
"""#

    private static let afterLoadLua = #"""
vim.bo.undolevels = 1000
vim.bo.modified = false
vim.cmd('silent! clearjumps')
vim.v.errmsg = ''
vim.v.statusmsg = ''
"""#

    private static let snapshotLua = #"""
local mode = vim.fn.mode(1)
local cursor = vim.api.nvim_win_get_cursor(0)
local visual = nil
if mode == 'v' or mode == 'V' or mode == string.char(22) or mode:sub(1, 2) == 'vs' then
  local anchor = vim.fn.getpos('v')
  visual = { anchor[2] - 1, math.max(0, anchor[3] - 1), mode:sub(1, 1) }
end
local command = ''
local command_type = vim.fn.getcmdtype()
if command_type ~= '' then
  command = command_type .. vim.fn.getcmdline()
end
local result = {
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, true),
  cursor = cursor,
  mode = mode,
  visual = visual,
  operator = vim.v.operator or '',
  count = vim.v.count or 0,
  command = command,
  error = vim.v.errmsg or '',
  info = vim.v.statusmsg or '',
}
vim.v.errmsg = ''
vim.v.statusmsg = ''
return result
"""#
}

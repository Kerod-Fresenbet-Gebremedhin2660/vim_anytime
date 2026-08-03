import Foundation

public enum MessagePackRPCError: Error, LocalizedError, Sendable {
    case closed(String)
    case malformedMessage
    case remote(String)
    case timedOut(method: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .closed(let reason): return "Neovim RPC connection closed: \(reason)"
        case .malformedMessage: return "Neovim sent a malformed MessagePack-RPC message."
        case .remote(let message): return "Neovim RPC error: \(message)"
        case .timedOut(let method): return "Neovim RPC method \(method) timed out."
        case .transport(let message): return "Neovim RPC transport failed: \(message)"
        }
    }
}

public final class MessagePackRPCClient: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (String, [MessagePackValue]) throws -> MessagePackValue
    public typealias NotificationHandler = @Sendable (String, [MessagePackValue]) -> Void

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<MessagePackValue, Error>
    }

    private let input: FileHandle
    private let output: FileHandle
    private let logger = DiagnosticLogger.shared
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let decodeQueue = DispatchQueue(label: "dev.vimany.msgpack.decode", qos: .userInteractive)
    private var buffer = Data()
    private var nextMessageID: Int64 = 1
    private var pending: [Int64: PendingRequest] = [:]
    private var closeError: Error?
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private let mirrorsDebugToStandardError = ProcessInfo.processInfo.environment["VIMANY_RPC_DEBUG"] == "1"

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
        logger.info("RPC", "client initialized")
        beginReading()
    }

    deinit {
        input.readabilityHandler = nil
    }

    public func setRequestHandler(_ handler: RequestHandler?) {
        stateLock.withLock { requestHandler = handler }
    }

    public func setNotificationHandler(_ handler: NotificationHandler?) {
        stateLock.withLock { notificationHandler = handler }
    }

    public func request(
        method: String,
        parameters: [MessagePackValue] = [],
        timeout: TimeInterval = 5
    ) async throws -> MessagePackValue {
        let messageID: Int64 = try stateLock.withLock {
            if let closeError { throw closeError }
            defer { nextMessageID += 1 }
            return nextMessageID
        }

        return try await withCheckedThrowingContinuation { continuation in
            let shouldWrite: Bool = stateLock.withLock {
                if let closeError {
                    continuation.resume(throwing: closeError)
                    return false
                }
                pending[messageID] = PendingRequest(method: method, continuation: continuation)
                return true
            }
            guard shouldWrite else { return }

            do {
                debug("send request \(messageID) \(method)")
                try write(.array([
                    .int(0),
                    .int(messageID),
                    .string(method),
                    .array(parameters),
                ]))
            } catch {
                failPending(messageID: messageID, error: error)
                return
            }

            if timeout > 0 {
                Task.detached { [weak self] in
                    let nanoseconds = UInt64(timeout * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    self?.timeOut(messageID: messageID, method: method)
                }
            }
        }
    }

    public func notify(method: String, parameters: [MessagePackValue] = []) throws {
        debug("send notification \(method)")
        try stateLock.withLock {
            if let closeError { throw closeError }
        }
        try write(.array([
            .int(2),
            .string(method),
            .array(parameters),
        ]))
    }

    public func close(reason: String = "end of file") {
        close(with: MessagePackRPCError.closed(reason))
    }

    private func beginReading() {
        debug("begin reading")
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.debug("read EOF")
                self.close(reason: "Neovim exited")
                return
            }
            self.decodeQueue.async { [weak self] in
                self?.debug("read \(data.count) bytes")
                self?.consume(data)
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        if buffer.count > 128 * 1_024 * 1_024 {
            close(with: MessagePackRPCError.malformedMessage)
            return
        }

        while !buffer.isEmpty {
            do {
                let decoded = try MessagePackDecoder.decodeOne(from: buffer)
                debug("decoded frame of \(decoded.consumed) bytes")
                buffer.removeFirst(decoded.consumed)
                handle(decoded.value)
            } catch MessagePackCodingError.needMoreData {
                return
            } catch {
                logger.error("RPC", error: error, context: "MessagePack decode failed")
                close(with: error)
                return
            }
        }
    }

    private func handle(_ value: MessagePackValue) {
        guard case .array(let parts) = value,
              let kind = parts.first?.intValue else {
            logger.error("RPC", "received malformed top-level frame")
            close(with: MessagePackRPCError.malformedMessage)
            return
        }

        switch kind {
        case 0:
            handleIncomingRequest(parts)
        case 1:
            handleResponse(parts)
        case 2:
            handleNotification(parts)
        default:
            logger.error("RPC", "received unknown message kind=\(kind)")
            close(with: MessagePackRPCError.malformedMessage)
        }
    }

    private func handleResponse(_ parts: [MessagePackValue]) {
        guard parts.count == 4, let messageID = parts[1].intValue else {
            logger.error("RPC", "received malformed response")
            close(with: MessagePackRPCError.malformedMessage)
            return
        }

        let request = stateLock.withLock { pending.removeValue(forKey: messageID) }
        guard let request else { return }
        debug("receive response \(messageID) \(request.method)")

        if parts[2] == .null {
            request.continuation.resume(returning: parts[3])
        } else {
            let message = describe(parts[2])
            logger.error("RPC", "remote error method=\(request.method) message=\(message)")
            request.continuation.resume(throwing: MessagePackRPCError.remote(message))
        }
    }

    private func handleIncomingRequest(_ parts: [MessagePackValue]) {
        guard parts.count == 4,
              let messageID = parts[1].intValue,
              let method = parts[2].stringValue,
              let parameters = parts[3].arrayValue else {
            logger.error("RPC", "received malformed host request")
            close(with: MessagePackRPCError.malformedMessage)
            return
        }

        let handler = stateLock.withLock { requestHandler }
        debug("receive host request \(messageID) \(method)")
        do {
            let result = try handler?(method, parameters) ?? .null
            try write(.array([.int(1), .int(messageID), .null, result]))
        } catch {
            logger.error("RPC", error: error, context: "host request failed method=\(method)")
            let rpcError: MessagePackValue = .array([
                .int(0),
                .string(error.localizedDescription),
            ])
            try? write(.array([.int(1), .int(messageID), rpcError, .null]))
        }
    }

    private func handleNotification(_ parts: [MessagePackValue]) {
        guard parts.count == 3,
              let method = parts[1].stringValue,
              let parameters = parts[2].arrayValue else {
            logger.error("RPC", "received malformed notification")
            close(with: MessagePackRPCError.malformedMessage)
            return
        }
        let handler = stateLock.withLock { notificationHandler }
        debug("receive notification \(method)")
        handler?(method, parameters)
    }

    private func write(_ value: MessagePackValue) throws {
        let data = MessagePackEncoder.encode(value)
        do {
            try writeLock.withLock {
                try output.write(contentsOf: data)
            }
        } catch {
            let wrapped = MessagePackRPCError.transport(error.localizedDescription)
            logger.error("RPC", error: wrapped, context: "transport write failed")
            close(with: wrapped)
            throw wrapped
        }
    }

    private func timeOut(messageID: Int64, method: String) {
        let request = stateLock.withLock { pending.removeValue(forKey: messageID) }
        guard let request else { return }
        let error = MessagePackRPCError.timedOut(method: method)
        logger.error("RPC", "request timed out id=\(messageID) method=\(method)")
        request.continuation.resume(throwing: error)
    }

    private func failPending(messageID: Int64, error: Error) {
        let request = stateLock.withLock { pending.removeValue(forKey: messageID) }
        if request != nil {
            logger.warning(
                "RPC",
                "pending request failed id=\(messageID) method=\(request?.method ?? "unknown") "
                    + "error=\(error.localizedDescription)"
            )
        }
        request?.continuation.resume(throwing: error)
    }

    private func close(with error: Error) {
        let requests: [PendingRequest] = stateLock.withLock {
            guard closeError == nil else { return [] }
            closeError = error
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        input.readabilityHandler = nil
        let expectedClosure: Bool
        if let rpcError = error as? MessagePackRPCError,
           case .closed(let reason) = rpcError {
            expectedClosure = reason == "VimAny is stopping" || reason == "Restarting Neovim"
        } else {
            expectedClosure = false
        }
        if expectedClosure {
            logger.info(
                "RPC",
                "client closed normally pendingCount=\(requests.count) reason=\(error.localizedDescription)"
            )
        } else {
            logger.warning(
                "RPC",
                "client closed pendingCount=\(requests.count) reason=\(error.localizedDescription)"
            )
        }
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    private func describe(_ value: MessagePackValue) -> String {
        if let string = value.stringValue { return string }
        if let values = value.arrayValue {
            return values.compactMap(\.stringValue).joined(separator: ": ")
        }
        return String(describing: value)
    }

    private func debug(_ message: String) {
        logger.debug("RPC", message)
        guard mirrorsDebugToStandardError else { return }
        let line = Data("[VimAny RPC] \(message)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: line)
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

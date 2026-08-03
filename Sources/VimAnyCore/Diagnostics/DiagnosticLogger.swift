import Foundation

public enum DiagnosticLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Thread-safe, line-oriented diagnostics for development and support.
///
/// Log messages must describe text and clipboard values by size or coordinates;
/// callers should never pass the values themselves.
public final class DiagnosticLogger: @unchecked Sendable {
    public static let shared = DiagnosticLogger(fileURL: defaultFileURL())

    public let fileURL: URL

    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    private var handle: FileHandle?

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                guard FileManager.default.createFile(atPath: self.fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forWritingTo: self.fileURL)
            try handle?.seekToEnd()
        } catch {
            handle = nil
            Self.writeToStandardError(
                "[VimAny Logger] Could not open \(self.fileURL.path): \(error.localizedDescription)\n"
            )
        }

        info(
            "Session",
            "start pid=\(ProcessInfo.processInfo.processIdentifier) "
                + "process=\(ProcessInfo.processInfo.processName) "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "bundle=\(Bundle.main.bundleURL.path) log=\(self.fileURL.path)"
        )
    }

    deinit {
        flush()
        try? handle?.close()
    }

    public func debug(
        _ category: String,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        log(.debug, category: category, message(), fileID: fileID, line: line)
    }

    public func info(
        _ category: String,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        log(.info, category: category, message(), fileID: fileID, line: line)
    }

    public func warning(
        _ category: String,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        log(.warning, category: category, message(), fileID: fileID, line: line)
    }

    public func error(
        _ category: String,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        log(.error, category: category, message(), fileID: fileID, line: line)
    }

    public func error(
        _ category: String,
        error: Error,
        context: String,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        log(
            .error,
            category: category,
            "\(context): \(error.localizedDescription)",
            fileID: fileID,
            line: line
        )
    }

    public func flush() {
        lock.withLock {
            try? handle?.synchronize()
        }
    }

    private func log(
        _ level: DiagnosticLogLevel,
        category: String,
        _ message: String,
        fileID: String,
        line: Int
    ) {
        lock.withLock {
            let timestamp = formatter.string(from: Date())
            let safeCategory = Self.singleLine(category)
            let safeMessage = Self.singleLine(message)
            let entry = "\(timestamp) [\(level.rawValue)] [\(safeCategory)] "
                + "\(safeMessage) (\(fileID):\(line))\n"
            guard let handle else {
                Self.writeToStandardError(entry)
                return
            }
            do {
                try handle.write(contentsOf: Data(entry.utf8))
                if level == .warning || level == .error {
                    try handle.synchronize()
                }
            } catch {
                Self.writeToStandardError(
                    "[VimAny Logger] Write failed: \(error.localizedDescription)\n\(entry)"
                )
            }
        }
    }

    private static func defaultFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["VIMANY_LOG_PATH"], !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath)
        }

        if environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("VimAny-tests-\(ProcessInfo.processInfo.processIdentifier).log")
        }

        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        if bundleParent.lastPathComponent == ".build" {
            return bundleParent.deletingLastPathComponent().appendingPathComponent("VimAny.log")
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
        if let projectRoot = projectRoot(containing: sourceURL) {
            return projectRoot.appendingPathComponent("VimAny.log")
        }

        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        if let projectRoot = projectRoot(containing: currentDirectory) {
            return projectRoot.appendingPathComponent("VimAny.log")
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("VimAny", isDirectory: true)
            .appendingPathComponent("VimAny.log")
    }

    private static func projectRoot(containing url: URL) -> URL? {
        var candidate = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Package.swift").path
            ) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func writeToStandardError(_ value: String) {
        try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
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

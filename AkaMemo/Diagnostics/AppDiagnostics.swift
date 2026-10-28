import AkaMemoCore
import Foundation
import OSLog

/// App-wide diagnostics: OSLog + bounded memory buffer + JSONL file + live
/// stream for the diagnostics screen.
///
/// Messages are fixed templates; variables go through `LogSanitizer` metadata.
/// File writes happen on this actor, never on an audio callback.
actor AppDiagnostics {
    private static let debugDefaultsKey = "diagnostics.debugEnabled"

    private let subsystem: String
    private let defaults: UserDefaults
    private let fileLog: DiagnosticsFileLog
    private var buffer = LogRingBuffer(capacity: 2_000)
    private var continuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    private var loggers: [LogCategory: Logger] = [:]
    private var debugEnabled: Bool

    init(
        root: URL,
        subsystem: String = "com.ariakage.AkaMemo",
        defaultsSuiteName: String? = nil
    ) {
        let defaults =
            defaultsSuiteName.flatMap {
                UserDefaults(suiteName: $0)
            } ?? .standard
        self.subsystem = subsystem
        self.defaults = defaults
        self.fileLog = DiagnosticsFileLog(root: root)
        self.debugEnabled = defaults.bool(forKey: Self.debugDefaultsKey)
    }

    func setDebugEnabled(_ enabled: Bool) {
        debugEnabled = enabled
        defaults.set(enabled, forKey: Self.debugDefaultsKey)
    }

    func isDebugEnabled() -> Bool {
        debugEnabled
    }

    func log(
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: [String: String] = [:],
        source: LogSource = .iphone
    ) async {
        guard level != .debug || debugEnabled else {
            return
        }
        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            metadata: metadata,
            source: source
        )
        buffer.append(entry)
        writeOSLog(entry)
        for continuation in continuations.values {
            continuation.yield(entry)
        }
        do {
            try await fileLog.append(entry)
        } catch {
            buffer.append(
                LogEntry(
                    level: .warning,
                    category: .diagnostics,
                    message: "file log write failed",
                    metadata: ["errorCode": "writeFailed"],
                    source: .iphone
                )
            )
        }
    }

    func snapshot() -> [LogEntry] {
        buffer.entries
    }

    func droppedCount() -> Int {
        buffer.droppedCount
    }

    func clear() async {
        buffer.removeAll()
        try? await fileLog.clear()
    }

    func exportJSONL() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var lines: [String] = []
        for entry in buffer.entries {
            if let data = try? encoder.encode(entry),
                let line = String(data: data, encoding: .utf8)
            {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    func stream() -> AsyncStream<LogEntry> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func writeOSLog(_ entry: LogEntry) {
        let logger: Logger
        if let existing = loggers[entry.category] {
            logger = existing
        } else {
            let created = Logger(
                subsystem: subsystem,
                category: entry.category.rawValue
            )
            loggers[entry.category] = created
            logger = created
        }
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let text =
            metadata.isEmpty
            ? entry.message
            : "\(entry.message) \(metadata)"
        switch entry.level {
        case .debug:
            logger.debug("\(text, privacy: .public)")
        case .info:
            logger.info("\(text, privacy: .public)")
        case .warning:
            logger.warning("\(text, privacy: .public)")
        case .error:
            logger.error("\(text, privacy: .public)")
        }
    }
}

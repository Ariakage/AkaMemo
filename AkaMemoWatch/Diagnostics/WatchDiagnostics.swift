import AkaMemoCore
import Foundation
import OSLog

protocol DiagnosticsTransport: Sendable {
    /// Queues a batch for the iPhone. Returns false when WatchConnectivity is
    /// unavailable; the entries stay buffered for the next flush.
    func sendDiagnostics(_ batch: DiagnosticsBatch) -> Bool
}

/// Watch-side log buffer. Entries are bounded, sanitized by `LogEntry`, and
/// forwarded in small batches with `transferUserInfo` so an unreachable phone
/// does not grow the buffer without limit.
actor WatchDiagnostics {
    static let capacity = 500
    static let flushInterval: TimeInterval = 30

    private let transport: (any DiagnosticsTransport)?
    private let logger = Logger(
        subsystem: "com.ariakage.AkaMemo.watchkitapp",
        category: "diagnostics"
    )
    private var buffer: [LogEntry] = []
    private var droppedCount = 0
    private var isFlushing = false
    private var flushTask: Task<Void, Never>?

    init(transport: (any DiagnosticsTransport)?) {
        self.transport = transport
    }

    func start() {
        guard flushTask == nil else {
            return
        }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.flushInterval)
                )
                await self?.flush()
            }
        }
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
    }

    func log(
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            metadata: metadata,
            source: .watch
        )
        buffer.append(entry)
        if buffer.count > Self.capacity {
            let overflow = buffer.count - Self.capacity
            buffer.removeFirst(overflow)
            droppedCount += overflow
        }
        writeOSLog(entry)
        if buffer.count >= DiagnosticsBatch.maximumEntryCount {
            Task { await self.flush() }
        }
    }

    func flush() {
        guard !isFlushing, let transport, !buffer.isEmpty else {
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        while !buffer.isEmpty {
            let entries = Array(
                buffer.prefix(DiagnosticsBatch.maximumEntryCount)
            )
            let batch = DiagnosticsBatch(
                entries: entries,
                sentAtMs: TimeMath.epochMs(Date())
            )
            guard transport.sendDiagnostics(batch) else {
                return
            }
            buffer.removeFirst(entries.count)
        }
    }

    func snapshot() -> [LogEntry] {
        buffer
    }

    func dropped() -> Int {
        droppedCount
    }

    func clear() {
        buffer.removeAll()
    }

    private func writeOSLog(_ entry: LogEntry) {
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

import Foundation

public enum LogLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    public var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum LogCategory: String, Codable, CaseIterable, Sendable {
    case recording
    case transfer
    case transcription
    case storage
    case location
    case battery
    case ui
    case diagnostics
}

public enum LogSource: String, Codable, CaseIterable, Sendable {
    case iphone
    case watch
}

public struct LogEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let metadata: [String: String]
    public let source: LogSource

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: [String: String] = [:],
        source: LogSource
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = LogSanitizer.message(message)
        self.metadata = LogSanitizer.metadata(metadata)
        self.source = source
    }
}

/// The only place that decides what may enter a log entry.
public enum LogSanitizer {
    /// Metadata keys whitelisted for diagnostics. Additions require a privacy
    /// review and a docs update.
    public static let allowedMetadataKeys: Set<String> = [
        "attempt",
        "batteryPercent",
        "byteSize",
        "chunkSeq",
        "count",
        "dropped",
        "durationMs",
        "errorCode",
        "failed",
        "gapMs",
        "phase",
        "scope",
        "state",
        "status",
        "succeeded",
        "version",
    ]

    public static let maxMessageLength = 200
    public static let maxMetadataValueLength = 64

    public static func redactedID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    public static func message(_ message: String) -> String {
        let cleaned =
            message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .filter { !$0.isNewline && !isControl($0) }
        return String(cleaned.prefix(maxMessageLength))
    }

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }

    public static func metadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata
        where allowedMetadataKeys.contains(key) {
            let cleaned =
                value
                .replacingOccurrences(of: "\n", with: " ")
                .filter { !$0.isNewline && !isControl($0) }
            guard !cleaned.contains("/"), !cleaned.contains("\\") else {
                continue
            }
            result[key] = String(cleaned.prefix(maxMetadataValueLength))
        }
        return result
    }
}

/// Fixed-capacity in-memory buffer. The oldest entries are dropped first.
public struct LogRingBuffer: Sendable, Equatable {
    public let capacity: Int
    public private(set) var entries: [LogEntry] = []
    public private(set) var droppedCount = 0

    public init(capacity: Int = 2_000) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
            droppedCount += 1
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
        droppedCount = 0
    }
}

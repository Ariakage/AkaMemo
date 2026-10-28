import Foundation

public enum StorageBand: String, Codable, Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown
}

/// Watch storage thresholds from `docs/specs/recording.md` §9.2.
public struct RecordingStoragePolicy: Sendable, Equatable {
    public static let standard = RecordingStoragePolicy()

    public let warningBytes: Int64
    public let criticalBytes: Int64

    public init(
        warningBytes: Int64 = 1_000_000_000,
        criticalBytes: Int64 = 500_000_000
    ) {
        self.warningBytes = warningBytes
        self.criticalBytes = criticalBytes
    }

    public func band(forAvailableBytes bytes: Int64?) -> StorageBand {
        guard let bytes, bytes >= 0 else {
            return .unknown
        }
        if bytes < criticalBytes {
            return .critical
        }
        if bytes < warningBytes {
            return .warning
        }
        return .normal
    }
}

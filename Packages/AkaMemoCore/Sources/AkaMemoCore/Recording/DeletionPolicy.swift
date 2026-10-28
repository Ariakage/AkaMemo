import Foundation

public enum TimeMath {
    public static func epochMs(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite else {
            return 0
        }
        if value >= Double(Int64.max) {
            return Int64.max
        }
        if value <= Double(Int64.min) {
            return Int64.min
        }
        return Int64(value.rounded())
    }

    public static func date(epochMs: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
    }
}

/// The global "delete all data" boundary.
///
/// A session is deleted only when its *start* is older than the epoch. A
/// chunk that began after the epoch but belongs to an older session must still
/// be rejected, so callers use `sessionStartedAt`, never the chunk timestamp.
public struct DataEpochPolicy: Sendable, Equatable {
    public let epochMs: Int64

    public init(epochMs: Int64) {
        self.epochMs = epochMs
    }

    public init(epoch: DataEpoch) {
        self.epochMs = epoch.epoch
    }

    public func isDeleted(sessionStartedAtMs: Int64) -> Bool {
        sessionStartedAtMs < epochMs
    }

    public func isDeleted(session: RecordingSession) -> Bool {
        isDeleted(sessionStartedAtMs: TimeMath.epochMs(session.startedAt))
    }

    public func shouldReject(chunk: AudioChunk) -> Bool {
        isDeleted(sessionStartedAtMs: TimeMath.epochMs(chunk.sessionStartedAt))
    }
}

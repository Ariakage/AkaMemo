import Foundation

/// A slice of a chunk that is sent to the recognizer in one request.
///
/// Offsets are relative to the start of the chunk audio.
public struct TranscriptionWindow: Sendable, Equatable {
    public let offsetMs: Int64
    public let durationMs: Int64

    public init(offsetMs: Int64, durationMs: Int64) {
        self.offsetMs = offsetMs
        self.durationMs = durationMs
    }

    public var endMs: Int64 {
        offsetMs + durationMs
    }
}

public enum TranscriptionWindowPlanner {
    /// Apple Speech recommends requests of about one minute or less; 50 s
    /// leaves headroom for encoder priming and long chunks.
    public static let defaultMaxWindowMs: Int64 = 50_000

    /// Splits a chunk into consecutive windows. A non-positive duration yields
    /// no windows; a duration within the limit yields one window.
    public static func plan(
        durationMs: Int64,
        maxWindowMs: Int64 = defaultMaxWindowMs
    ) -> [TranscriptionWindow] {
        guard durationMs > 0, maxWindowMs > 0 else {
            return []
        }
        var windows: [TranscriptionWindow] = []
        var offset: Int64 = 0
        while offset < durationMs {
            let remaining = durationMs - offset
            let length = min(remaining, maxWindowMs)
            windows.append(
                TranscriptionWindow(offsetMs: offset, durationMs: length)
            )
            offset += length
        }
        return windows
    }

    /// Maps a window-relative segment offset to absolute Unix milliseconds.
    public static func absoluteStartMs(
        chunkStartedAtMs: Int64,
        windowOffsetMs: Int64,
        segmentOffsetMs: Int64
    ) -> Int64 {
        chunkStartedAtMs + windowOffsetMs + segmentOffsetMs
    }
}

public enum TranscriptionErrorCode: String, Codable, Sendable, Equatable {
    case decodeFailed = "decode_failed"
    case unsupportedFormat = "unsupported_format"
    case engineUnavailable = "engine_unavailable"
    case permissionDenied = "permission_denied"
    case audioMissing = "audio_missing"
    case cancelled = "cancelled"
    case unknown = "unknown"
}

public struct TranscriptionFailure: Error, Codable, Sendable, Equatable {
    public let code: TranscriptionErrorCode

    public init(code: TranscriptionErrorCode) {
        self.code = code
    }

    public var localizedDescription: String {
        code.rawValue
    }
}

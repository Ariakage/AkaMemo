import Foundation

/// Decides when the active chunk must be sealed.
///
/// A chunk is sealed after 60 seconds or 2 MB by default. Stop, pause,
/// interruption, route changes and audio-service resets seal immediately;
/// those events are handled by the recorder, not by this policy.
public struct ChunkPolicy: Sendable, Equatable {
    public static let standard = ChunkPolicy(
        duration: RecordingConfiguration.chunkDuration,
        maximumBytes: RecordingConfiguration.maximumChunkBytes
    )

    public let duration: TimeInterval
    public let maximumBytes: Int

    public init(duration: TimeInterval, maximumBytes: Int) {
        self.duration = duration
        self.maximumBytes = maximumBytes
    }

    public func shouldSeal(elapsed: TimeInterval, byteCount: Int) -> Bool {
        elapsed >= duration || byteCount >= maximumBytes
    }
}

public enum ChunkFileKind: String, Sendable, CaseIterable {
    case audio = "m4a"
    case metadata = "json"
}

public enum ChunkFileSuffix: String, Sendable {
    case final = ""
    case part = ".part"
    case corrupt = ".corrupt"
}

public struct ParsedChunkFileName: Sendable, Equatable {
    public let sequence: Int
    public let startEpochMs: Int64
    public let kind: ChunkFileKind
    public let suffix: ChunkFileSuffix

    public init(sequence: Int, startEpochMs: Int64, kind: ChunkFileKind, suffix: ChunkFileSuffix) {
        self.sequence = sequence
        self.startEpochMs = startEpochMs
        self.kind = kind
        self.suffix = suffix
    }
}

/// Builds and parses chunk file names.
///
/// Names contain only a sequence, a UTC timestamp and a format extension.
/// Titles, transcripts, contacts or places must never appear in a file name.
public enum ChunkPath {
    public static func fileName(
        sequence: Int,
        startEpochMs: Int64,
        kind: ChunkFileKind,
        suffix: ChunkFileSuffix = .final
    ) -> String {
        precondition(sequence >= 0, "chunk sequence must be non-negative")
        precondition(startEpochMs > 0, "chunk start must be a positive UTC timestamp")
        let paddedSequence = String(format: "%04d", sequence)
        return "\(paddedSequence)-\(startEpochMs).\(kind.rawValue)\(suffix.rawValue)"
    }

    public static func sessionRelativePath(
        sessionID: UUID,
        sequence: Int,
        startEpochMs: Int64,
        kind: ChunkFileKind,
        suffix: ChunkFileSuffix = .final
    ) -> String {
        "audio/\(sessionID.uuidString)/"
            + fileName(sequence: sequence, startEpochMs: startEpochMs, kind: kind, suffix: suffix)
    }

    public static func parseFileName(_ name: String) -> ParsedChunkFileName? {
        var body = name
        let suffix: ChunkFileSuffix
        if body.hasSuffix(ChunkFileSuffix.corrupt.rawValue) {
            body.removeLast(ChunkFileSuffix.corrupt.rawValue.count)
            suffix = .corrupt
        } else if body.hasSuffix(ChunkFileSuffix.part.rawValue) {
            body.removeLast(ChunkFileSuffix.part.rawValue.count)
            suffix = .part
        } else {
            suffix = .final
        }

        guard let kind = ChunkFileKind.allCases.first(where: { body.hasSuffix(".\($0.rawValue)") })
        else {
            return nil
        }
        body.removeLast(kind.rawValue.count + 1)

        let components = body.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
            let sequence = Int(components[0]),
            sequence >= 0,
            let startEpochMs = Int64(components[1]),
            startEpochMs > 0
        else {
            return nil
        }

        return ParsedChunkFileName(
            sequence: sequence,
            startEpochMs: startEpochMs,
            kind: kind,
            suffix: suffix
        )
    }
}

import Foundation

/// A file discovered while scanning a session directory.
public struct ChunkFileObservation: Sendable, Equatable, Hashable {
    public let sequence: Int
    public let startedAtMs: Int64

    public init(sequence: Int, startedAtMs: Int64) {
        self.sequence = sequence
        self.startedAtMs = startedAtMs
    }
}

/// Per-session index of chunks and their local lifecycle state.
///
/// The manifest is rebuilt from the file system on launch. Normal cleanup
/// must never be reported as a missing chunk, so `reclaimed`, `deleted`,
/// `audioPurged` and tombstones are preserved during reconciliation.
public struct ChunkManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct Entry: Codable, Sendable, Equatable {
        public var chunkID: UUID?
        public let sequence: Int
        public let startedAtMs: Int64
        public var localState: AudioChunk.LocalState
        public var tombstoneID: UUID?
        public var checksumSHA256: String?
        public var byteSize: Int?
        public var updatedAtMs: Int64

        public init(
            chunkID: UUID? = nil,
            sequence: Int,
            startedAtMs: Int64,
            localState: AudioChunk.LocalState = .present,
            tombstoneID: UUID? = nil,
            checksumSHA256: String? = nil,
            byteSize: Int? = nil,
            updatedAtMs: Int64
        ) {
            self.chunkID = chunkID
            self.sequence = sequence
            self.startedAtMs = startedAtMs
            self.localState = localState
            self.tombstoneID = tombstoneID
            self.checksumSHA256 = checksumSHA256
            self.byteSize = byteSize
            self.updatedAtMs = updatedAtMs
        }
    }

    public struct ReconcileResult: Sendable, Equatable {
        public let addedSequences: [Int]
        public let newlyMissingSequences: [Int]
        public let recoveredSequences: [Int]

        public init(
            addedSequences: [Int],
            newlyMissingSequences: [Int],
            recoveredSequences: [Int]
        ) {
            self.addedSequences = addedSequences
            self.newlyMissingSequences = newlyMissingSequences
            self.recoveredSequences = recoveredSequences
        }
    }

    public let schemaVersion: Int
    public let sessionID: UUID
    public let sessionStartedAtMs: Int64
    public private(set) var entries: [Entry]

    public init(
        schemaVersion: Int = ChunkManifest.currentSchemaVersion,
        sessionID: UUID,
        sessionStartedAtMs: Int64,
        entries: [Entry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sessionStartedAtMs = sessionStartedAtMs
        self.entries = entries.sorted { $0.sequence < $1.sequence }
    }

    public func entry(sequence: Int) -> Entry? {
        entries.first { $0.sequence == sequence }
    }

    public mutating func upsert(_ entry: Entry) {
        entries.removeAll { $0.sequence == entry.sequence }
        entries.append(entry)
        entries.sort { $0.sequence < $1.sequence }
    }

    public mutating func setLocalState(
        sequence: Int,
        localState: AudioChunk.LocalState,
        tombstoneID: UUID? = nil,
        nowMs: Int64
    ) {
        guard let index = entries.firstIndex(where: { $0.sequence == sequence }) else {
            return
        }
        entries[index].localState = localState
        if let tombstoneID {
            entries[index].tombstoneID = tombstoneID
        }
        entries[index].updatedAtMs = nowMs
    }

    /// Reconciles the manifest with the files currently on disk.
    ///
    /// Rules from `docs/specs/recording-health.md` §5.2:
    /// - files not in the manifest are added as `present`;
    /// - `reclaimed`, `deleted`, `audioPurged` and tombstoned entries keep
    ///   their state when the file is gone;
    /// - an `present` entry whose file disappeared becomes `missing`;
    /// - a `missing` entry whose file reappears becomes `present`.
    @discardableResult
    public mutating func reconcile(
        with files: [ChunkFileObservation],
        nowMs: Int64
    ) -> ReconcileResult {
        let orderedFiles = files.sorted {
            ($0.sequence, $0.startedAtMs) < ($1.sequence, $1.startedAtMs)
        }
        var filesBySequence: [Int: ChunkFileObservation] = [:]
        for file in orderedFiles where filesBySequence[file.sequence] == nil {
            filesBySequence[file.sequence] = file
        }

        var addedSequences: [Int] = []
        var newlyMissingSequences: [Int] = []
        var recoveredSequences: [Int] = []
        var knownSequences = Set(entries.map(\.sequence))

        for index in entries.indices {
            let sequence = entries[index].sequence
            if filesBySequence[sequence] != nil {
                if entries[index].localState == .missing {
                    entries[index].localState = .present
                    entries[index].updatedAtMs = nowMs
                    recoveredSequences.append(sequence)
                }
                continue
            }

            guard entries[index].localState == .present,
                entries[index].tombstoneID == nil
            else {
                continue
            }
            entries[index].localState = .missing
            entries[index].updatedAtMs = nowMs
            newlyMissingSequences.append(sequence)
        }

        for (sequence, file) in filesBySequence where !knownSequences.contains(sequence) {
            entries.append(
                Entry(
                    sequence: sequence,
                    startedAtMs: file.startedAtMs,
                    localState: .present,
                    updatedAtMs: nowMs
                )
            )
            knownSequences.insert(sequence)
            addedSequences.append(sequence)
        }

        entries.sort { $0.sequence < $1.sequence }

        return ReconcileResult(
            addedSequences: addedSequences.sorted(),
            newlyMissingSequences: newlyMissingSequences.sorted(),
            recoveredSequences: recoveredSequences.sorted()
        )
    }
}

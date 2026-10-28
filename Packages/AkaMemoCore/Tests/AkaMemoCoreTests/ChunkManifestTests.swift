import XCTest

@testable import AkaMemoCore

final class ChunkManifestTests: XCTestCase {
    private let sessionID = UUID()

    private func makeManifest(
        _ entries: [ChunkManifest.Entry]
    ) -> ChunkManifest {
        ChunkManifest(sessionID: sessionID, sessionStartedAtMs: 1_000, entries: entries)
    }

    private func entry(
        sequence: Int,
        state: AudioChunk.LocalState = .present,
        tombstoneID: UUID? = nil
    ) -> ChunkManifest.Entry {
        ChunkManifest.Entry(
            sequence: sequence,
            startedAtMs: Int64(1_000 + sequence),
            localState: state,
            tombstoneID: tombstoneID,
            updatedAtMs: 1_000
        )
    }

    func testReconcile_marksOnlyPresentEntriesMissing() {
        let tombstone = UUID()
        var manifest = makeManifest([
            entry(sequence: 0),
            entry(sequence: 1, state: .reclaimed),
            entry(sequence: 2, state: .deleted),
            entry(sequence: 3, state: .audioPurged),
            entry(sequence: 4, state: .present, tombstoneID: tombstone),
            entry(sequence: 5, state: .missing),
        ])

        let result = manifest.reconcile(with: [], nowMs: 9_000)

        XCTAssertEqual(result.newlyMissingSequences, [0])
        XCTAssertEqual(result.recoveredSequences, [])
        XCTAssertEqual(result.addedSequences, [])
        XCTAssertEqual(manifest.entry(sequence: 0)?.localState, .missing)
        XCTAssertEqual(manifest.entry(sequence: 1)?.localState, .reclaimed)
        XCTAssertEqual(manifest.entry(sequence: 2)?.localState, .deleted)
        XCTAssertEqual(manifest.entry(sequence: 3)?.localState, .audioPurged)
        XCTAssertEqual(manifest.entry(sequence: 4)?.localState, .present)
        XCTAssertEqual(manifest.entry(sequence: 5)?.localState, .missing)
    }

    func testReconcile_addsFilesFoundOnDisk() {
        var manifest = makeManifest([])
        let files = [
            ChunkFileObservation(sequence: 1, startedAtMs: 2_000),
            ChunkFileObservation(sequence: 0, startedAtMs: 1_000),
        ]

        let result = manifest.reconcile(with: files, nowMs: 9_000)

        XCTAssertEqual(result.addedSequences, [0, 1])
        XCTAssertEqual(manifest.entries.map(\.sequence), [0, 1])
        XCTAssertEqual(manifest.entry(sequence: 0)?.localState, .present)
        XCTAssertEqual(manifest.entry(sequence: 1)?.localState, .present)
    }

    func testReconcile_recoversMissingEntryWhenFileReappears() {
        var manifest = makeManifest([entry(sequence: 0, state: .missing)])
        let files = [ChunkFileObservation(sequence: 0, startedAtMs: 1_000)]

        let result = manifest.reconcile(with: files, nowMs: 9_000)

        XCTAssertEqual(result.recoveredSequences, [0])
        XCTAssertEqual(manifest.entry(sequence: 0)?.localState, .present)
    }

    func testReconcile_isIdempotent() {
        var manifest = makeManifest([entry(sequence: 0)])
        let files = [ChunkFileObservation(sequence: 0, startedAtMs: 1_000)]

        let first = manifest.reconcile(with: files, nowMs: 9_000)
        let snapshot = manifest
        let second = manifest.reconcile(with: files, nowMs: 9_000)

        XCTAssertEqual(first.newlyMissingSequences, [])
        XCTAssertEqual(second.addedSequences, [])
        XCTAssertEqual(second.newlyMissingSequences, [])
        XCTAssertEqual(second.recoveredSequences, [])
        XCTAssertEqual(manifest, snapshot)
    }

    func testUpsertReplacesEntryAndKeepsOrder() {
        var manifest = makeManifest([
            entry(sequence: 2),
            entry(sequence: 0),
        ])
        manifest.upsert(
            ChunkManifest.Entry(
                sequence: 1,
                startedAtMs: 1_001,
                localState: .audioPurged,
                tombstoneID: UUID(),
                updatedAtMs: 5_000
            )
        )
        XCTAssertEqual(manifest.entries.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(manifest.entry(sequence: 1)?.localState, .audioPurged)
    }

    func testSetLocalStateRecordsTombstone() {
        var manifest = makeManifest([entry(sequence: 0)])
        let tombstone = UUID()

        manifest.setLocalState(
            sequence: 0, localState: .deleted, tombstoneID: tombstone, nowMs: 7_000)

        XCTAssertEqual(manifest.entry(sequence: 0)?.localState, .deleted)
        XCTAssertEqual(manifest.entry(sequence: 0)?.tombstoneID, tombstone)
        XCTAssertEqual(manifest.entry(sequence: 0)?.updatedAtMs, 7_000)
    }
}

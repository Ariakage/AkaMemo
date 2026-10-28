import Foundation
import SQLite3

/// Local SQLite FTS5 sidecar index (ADR-0010).
///
/// Two FTS tables back the same `segments` table: a trigram table for queries
/// of three or more characters, and a short-token table with pre-tokenized
/// unigrams/bigrams for one- and two-character queries. Everything stays in
/// the app container; nothing is registered with Spotlight or uploaded.
public actor SQLiteSearchIndex: SearchIndexing {
    public enum IndexError: Error, Equatable, Sendable {
        case openFailed(String)
        case sqlite(String)
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY,
            chunk_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            language TEXT NOT NULL,
            engine TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS segments_chunk ON segments(chunk_id);
        CREATE INDEX IF NOT EXISTS segments_session ON segments(session_id);
        CREATE INDEX IF NOT EXISTS segments_start ON segments(start_ms);
        CREATE VIRTUAL TABLE IF NOT EXISTS segment_fts
            USING fts5(segment_id UNINDEXED, text, tokenize='trigram');
        CREATE VIRTUAL TABLE IF NOT EXISTS segment_short
            USING fts5(segment_id UNINDEXED, tokens, tokenize='unicode61');
        """

    private enum Binding {
        case text(String)
        case int(Int64)
    }

    private let databaseHandle: SQLiteDatabaseHandle

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var opened: OpaquePointer?
        let flags =
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard
            sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK,
            let database = opened
        else {
            let message =
                opened.map {
                    String(cString: sqlite3_errmsg($0))
                } ?? "could not open index"
            if let opened {
                sqlite3_close(opened)
            }
            throw IndexError.openFailed(message)
        }

        sqlite3_busy_timeout(database, 5_000)
        do {
            try Self.executeSQL(database, "PRAGMA journal_mode=WAL;")
            try Self.executeSQL(database, Self.schema)
        } catch {
            sqlite3_close(database)
            throw error
        }
        self.databaseHandle = SQLiteDatabaseHandle(pointer: database)
    }

    // MARK: - Indexing

    public func replaceChunk(
        _ chunkID: UUID,
        with entries: [SearchIndexEntry]
    ) async throws {
        let database = try database()
        try begin(database)
        do {
            let staleIDs = try segmentIDs(
                column: "chunk_id",
                value: chunkID.uuidString,
                database: database
            )
            try deleteFTSRows(segmentIDs: staleIDs, database: database)
            try executeUpdate(
                "DELETE FROM segments WHERE chunk_id = ?;",
                bindings: [.text(chunkID.uuidString)],
                database: database
            )
            for entry in entries {
                try insert(entry, database: database)
            }
            try commit(database)
        } catch {
            rollback(database)
            throw error
        }
    }

    public func replaceAll(_ entries: [SearchIndexEntry]) async throws {
        let database = try database()
        try begin(database)
        do {
            try Self.executeSQL(database, "DELETE FROM segment_fts;")
            try Self.executeSQL(database, "DELETE FROM segment_short;")
            try Self.executeSQL(database, "DELETE FROM segments;")
            for entry in entries {
                try insert(entry, database: database)
            }
            try commit(database)
        } catch {
            rollback(database)
            throw error
        }
    }

    public func deleteChunk(_ chunkID: UUID) async throws {
        try await replaceChunk(chunkID, with: [])
    }

    public func deleteSession(_ sessionID: UUID) async throws {
        let database = try database()
        try begin(database)
        do {
            let staleIDs = try segmentIDs(
                column: "session_id",
                value: sessionID.uuidString,
                database: database
            )
            try deleteFTSRows(segmentIDs: staleIDs, database: database)
            try executeUpdate(
                "DELETE FROM segments WHERE session_id = ?;",
                bindings: [.text(sessionID.uuidString)],
                database: database
            )
            try commit(database)
        } catch {
            rollback(database)
            throw error
        }
    }

    public func deleteAll() async throws {
        let database = try database()
        try begin(database)
        do {
            try Self.executeSQL(database, "DELETE FROM segment_fts;")
            try Self.executeSQL(database, "DELETE FROM segment_short;")
            try Self.executeSQL(database, "DELETE FROM segments;")
            try commit(database)
        } catch {
            rollback(database)
            throw error
        }
    }

    public func entryCount() async throws -> Int {
        let database = try database()
        let statement = try prepare(
            "SELECT COUNT(*) FROM segments;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard try step(statement, database: database) else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Search

    public func search(_ query: SearchQuery) async throws -> [SearchHit] {
        let queryText = query.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !queryText.isEmpty, query.limit > 0,
            let mode = SearchText.mode(for: queryText)
        else {
            return []
        }
        let table = mode == .short ? "segment_short" : "segment_fts"
        let match: String?
        switch mode {
        case .short:
            match = SearchText.shortMatchExpression(for: queryText)
        case .trigram:
            match = SearchText.trigramMatchExpression(for: queryText)
        }
        guard let match else {
            return []
        }

        let database = try database()
        var sql = """
            SELECT s.id, s.chunk_id, s.session_id, s.start_ms, s.end_ms,
                   s.text, bm25(\(table)) AS rank
            FROM \(table)
            JOIN segments s ON s.id = \(table).segment_id
            WHERE \(table) MATCH ?
            """
        var bindings: [Binding] = [.text(match)]
        if let startMs = query.startMs {
            sql += " AND s.start_ms >= ?"
            bindings.append(.int(startMs))
        }
        if let endMs = query.endMs {
            sql += " AND s.end_ms <= ?"
            bindings.append(.int(endMs))
        }
        let fetchLimit = min(max(query.limit * 3, query.limit), 500)
        if query.sort == .newest {
            sql += " ORDER BY s.start_ms DESC LIMIT ?"
        } else {
            sql += " ORDER BY rank ASC LIMIT ?"
        }
        bindings.append(.int(Int64(fetchLimit)))

        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, at: Int32(offset + 1), statement: statement)
        }

        let nowMs = TimeMath.epochMs(Date())
        var hits: [SearchHit] = []
        while try step(statement, database: database) {
            guard
                let idString = columnText(statement, 0),
                let chunkString = columnText(statement, 1),
                let sessionString = columnText(statement, 2),
                let segmentID = UUID(uuidString: idString),
                let chunkID = UUID(uuidString: chunkString),
                let sessionID = UUID(uuidString: sessionString),
                let text = columnText(statement, 5)
            else {
                continue
            }
            let startMs = sqlite3_column_int64(statement, 3)
            let endMs = sqlite3_column_int64(statement, 4)
            let rank = sqlite3_column_double(statement, 6)
            let relevance = -rank
            let score: Double
            if query.sort == .newest {
                score = relevance
            } else {
                let ageDays = max(
                    0,
                    Double(nowMs - startMs) / 86_400_000
                )
                score = relevance / (1 + ageDays / 30)
            }
            hits.append(
                SearchHit(
                    segmentID: segmentID,
                    chunkID: chunkID,
                    sessionID: sessionID,
                    startMs: startMs,
                    endMs: endMs,
                    snippet: SearchText.snippet(
                        text: text,
                        query: queryText
                    ),
                    score: score
                )
            )
        }

        if query.sort == .relevance {
            hits.sort { $0.score > $1.score }
        }
        if hits.count > query.limit {
            hits.removeLast(hits.count - query.limit)
        }
        return hits
    }

    // MARK: - SQLite helpers

    private func database() throws -> OpaquePointer {
        databaseHandle.pointer
    }

    private func insert(
        _ entry: SearchIndexEntry,
        database: OpaquePointer
    ) throws {
        try deleteFTSRows(
            segmentIDs: [entry.segmentID.uuidString],
            database: database
        )
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO segments
                (id, chunk_id, session_id, start_ms, end_ms, text, language, engine)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(
            .text(entry.segmentID.uuidString),
            at: 1,
            statement: statement
        )
        try bind(.text(entry.chunkID.uuidString), at: 2, statement: statement)
        try bind(
            .text(entry.sessionID.uuidString),
            at: 3,
            statement: statement
        )
        try bind(.int(entry.startMs), at: 4, statement: statement)
        try bind(.int(entry.endMs), at: 5, statement: statement)
        try bind(.text(entry.text), at: 6, statement: statement)
        try bind(.text(entry.language), at: 7, statement: statement)
        try bind(.text(entry.providerVersion), at: 8, statement: statement)
        _ = try step(statement, database: database)

        let trigram = try prepare(
            "INSERT INTO segment_fts (segment_id, text) VALUES (?, ?);",
            database: database
        )
        defer { sqlite3_finalize(trigram) }
        try bind(
            .text(entry.segmentID.uuidString),
            at: 1,
            statement: trigram
        )
        try bind(.text(entry.text), at: 2, statement: trigram)
        _ = try step(trigram, database: database)

        let short = try prepare(
            "INSERT INTO segment_short (segment_id, tokens) VALUES (?, ?);",
            database: database
        )
        defer { sqlite3_finalize(short) }
        try bind(.text(entry.segmentID.uuidString), at: 1, statement: short)
        try bind(
            .text(SearchText.shortTokens(for: entry.text)),
            at: 2,
            statement: short
        )
        _ = try step(short, database: database)
    }

    private func deleteFTSRows(
        segmentIDs: [String],
        database: OpaquePointer
    ) throws {
        guard !segmentIDs.isEmpty else {
            return
        }
        for table in ["segment_fts", "segment_short"] {
            let statement = try prepare(
                "DELETE FROM \(table) WHERE segment_id = ?;",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            for segmentID in segmentIDs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(.text(segmentID), at: 1, statement: statement)
                _ = try step(statement, database: database)
            }
        }
    }

    private func segmentIDs(
        column: String,
        value: String,
        database: OpaquePointer
    ) throws -> [String] {
        let statement = try prepare(
            "SELECT id FROM segments WHERE \(column) = ?;",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(.text(value), at: 1, statement: statement)
        var ids: [String] = []
        while try step(statement, database: database) {
            if let id = columnText(statement, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    private func executeUpdate(
        _ sql: String,
        bindings: [Binding],
        database: OpaquePointer
    ) throws {
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, at: Int32(offset + 1), statement: statement)
        }
        _ = try step(statement, database: database)
    }

    private func begin(_ database: OpaquePointer) throws {
        try Self.executeSQL(database, "BEGIN IMMEDIATE;")
    }

    private func commit(_ database: OpaquePointer) throws {
        try Self.executeSQL(database, "COMMIT;")
    }

    private func rollback(_ database: OpaquePointer) {
        try? Self.executeSQL(database, "ROLLBACK;")
    }

    private static func executeSQL(
        _ database: OpaquePointer,
        _ sql: String
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let description =
                message.map { String(cString: $0) }
                ?? "sqlite error \(result)"
            if let message {
                sqlite3_free(message)
            }
            throw IndexError.sqlite(description)
        }
    }

    private func prepare(
        _ sql: String,
        database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(
        _ binding: Binding,
        at index: Int32,
        statement: OpaquePointer
    ) throws {
        let result: Int32
        switch binding {
        case .text(let value):
            result = value.withCString {
                sqlite3_bind_text(
                    statement,
                    index,
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        case .int(let value):
            result = sqlite3_bind_int64(statement, index, value)
        }
        guard result == SQLITE_OK else {
            throw IndexError.sqlite("could not bind parameter \(index)")
        }
    }

    private func step(
        _ statement: OpaquePointer,
        database: OpaquePointer
    ) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func columnText(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }
}

/// Owns the SQLite handle so the actor can stay `Sendable`; the handle is only
/// touched from the enclosing actor.
private final class SQLiteDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

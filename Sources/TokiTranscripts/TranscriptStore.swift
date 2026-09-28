/// TranscriptStore — raw libsqlite3 persistence for the transcript index.
import Foundation
import SQLite3
import TokiLogging
import TokiModels

/// SQLite transient-destructor marker (libsqlite3 copies the bytes).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let log = TokiLog.logger("transcripts")

/// Errors raised by `TranscriptStore`.
public enum TranscriptStoreError: Error, Sendable {
    case openFailed(Int32, String)
    case prepareFailed(Int32, String)
    case stepFailed(Int32, String)
    case execFailed(Int32, String)
}

/// Raw libsqlite3-backed store for transcript entries and per-file index state.
///
/// Not `Sendable`: it owns a non-thread-safe `sqlite3*` handle. It is intended to be owned by a
/// single actor (`TranscriptIndexer`), which provides serialization. All prepared statements are
/// finalized; all return codes are checked.
public final class TranscriptStore {
    private var db: OpaquePointer?

    /// Default database location: `~/Library/Application Support/Toki/index.sqlite3`.
    public static func defaultDatabaseURL() -> URL {
        AppSupportDirectory.url.appendingPathComponent("index.sqlite3")
    }

    /// Opens (creating if needed) the SQLite database at `databaseURL` and applies the schema.
    public init(databaseURL: URL) throws {
        // Ensure the parent directory exists.
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw TranscriptStoreError.openFailed(rc, msg)
        }
        self.db = handle

        // Before anything else, so every statement below waits out another connection's lock
        // instead of failing with SQLITE_BUSY: the index is opened by two connections (the
        // indexer's writer and the dashboard's reader) at the same moment on every launch.
        sqlite3_busy_timeout(handle, 5000)
        try Self.retryingWhileBusy { try self.configure() }
    }

    /// Switching to WAL (and creating the schema on a fresh file) needs a lock the busy
    /// handler does not always wait for — a concurrent open can still get SQLITE_BUSY there.
    /// Every step is idempotent, so the whole setup is simply retried for up to ~5 s.
    private static func retryingWhileBusy(_ body: () throws -> Void) throws {
        var attempt = 0
        while true {
            do {
                return try body()
            } catch let TranscriptStoreError.execFailed(code, _) where
                (code == SQLITE_BUSY || code == SQLITE_LOCKED) && attempt < 100 {
                attempt += 1
                if attempt == 1 { log.debug("transcript index busy while opening, retrying") }
                usleep(50_000)
            }
        }
    }

    private func configure() throws {
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        // Wait up to 5s for transient WAL locks (SQLITE_BUSY, code 5) instead of failing
        // immediately. Multiple connections to the same DB then queue rather than error.
        // (Also set above through the C API, before the first statement; kept here so the
        // setting is visible next to the other connection pragmas.)
        try exec("PRAGMA busy_timeout=5000;")
        // Read tuning, measured on a 9 MB / 36k-row index: memory-mapped I/O plus a larger
        // page cache cut a full-table scan from 7.4 ms to 5.2 ms (-30%). Both are advisory —
        // SQLite silently ignores them where unsupported — and neither changes durability,
        // which `synchronous` above owns.
        try exec("PRAGMA mmap_size=268435456;")   // 256 MB ceiling, not an allocation
        try exec("PRAGMA cache_size=-16000;")     // 16 MB, negative means KiB not pages
        try exec("PRAGMA temp_store=MEMORY;")
        try exec("PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit {
        sqlite3_finalize(insertEntryStatement)
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS file_state (
            path TEXT PRIMARY KEY,
            last_byte_offset INTEGER NOT NULL,
            last_known_size INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            device INTEGER NOT NULL,
            last_event_id INTEGER NOT NULL
        );
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS entries (
            request_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            cwd TEXT NOT NULL,
            model TEXT NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            ephemeral_5m_tokens INTEGER NOT NULL,
            ephemeral_1h_tokens INTEGER NOT NULL,
            web_search INTEGER NOT NULL,
            web_fetch INTEGER NOT NULL,
            is_sidechain INTEGER NOT NULL,
            billing INTEGER NOT NULL DEFAULT 0
        );
        """)

        try exec("CREATE INDEX IF NOT EXISTS idx_entries_timestamp ON entries(timestamp_ms);")

        // Where a Codex rollout's parse stood at `file_state.last_byte_offset`: the session,
        // cwd and model later usage lines inherit, and the line ordinal. Persisting it is what
        // lets a growing rollout be tailed instead of re-read from the start on every write.
        try exec("""
        CREATE TABLE IF NOT EXISTS codex_parse_context (
            path TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            cwd TEXT NOT NULL,
            model TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            saw_usage_record INTEGER NOT NULL DEFAULT 0,
            last_count_total INTEGER NOT NULL DEFAULT 0
        );
        """)

        // Columns added after a table first shipped: `CREATE TABLE IF NOT EXISTS` leaves an
        // existing table as it was, so an older index gets them here.
        try addColumnIfMissing("entries", "billing INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("codex_parse_context", "saw_usage_record INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("codex_parse_context", "last_count_total INTEGER NOT NULL DEFAULT 0")

        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Low-level helpers

    /// `ALTER TABLE … ADD COLUMN` unless `table` already has the column (named by the first
    /// word of `definition`).
    private func addColumnIfMissing(_ table: String, _ definition: String) throws {
        let column = String(definition.prefix { $0 != " " })
        let stmt = try prepare("PRAGMA table_info(\(table));")
        var present = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column { present = true }
        }
        sqlite3_finalize(stmt)
        if !present { try exec("ALTER TABLE \(table) ADD COLUMN \(definition);") }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw TranscriptStoreError.execFailed(rc, msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TranscriptStoreError.prepareFailed(rc, msg)
        }
        return stmt
    }

    private func errMsg() -> String { String(cString: sqlite3_errmsg(db)) }

    // MARK: - Entries

    /// Inserts or replaces a single entry, keyed on `request_id` (last-wins per D2).
    public func upsertEntry(_ record: TranscriptRecord) throws {
        try upsertEntries([record])
    }

    /// Inserts or replaces a batch of entries inside a single transaction (last-wins per D2).
    public func upsertEntries(_ records: [TranscriptRecord]) throws {
        guard !records.isEmpty else { return }
        try inTransaction { try insertEntries(records) }
    }

    /// Writes one indexing batch — every file's new records, its advanced offset, and (for a
    /// Codex rollout) its parse context — in a single transaction, so a file's offset can
    /// never be persisted without the records read up to it, or the other way round.
    public func apply(_ batch: [IndexedFile]) throws {
        guard !batch.isEmpty else { return }
        try inTransaction {
            for file in batch {
                try insertEntries(file.records)
                try upsertFileState(file.state)
                if let context = file.codexContext {
                    try upsertCodexContext(context, path: file.state.path)
                }
            }
        }
    }

    /// Runs `body` inside `BEGIN IMMEDIATE … COMMIT`, rolling back if it throws.
    private func inTransaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            log.error("transaction failed, rolling back \(error: error)")
            do {
                try exec("ROLLBACK;")
            } catch {
                log.error("rollback after failed transaction also failed \(error: error)")
            }
            throw error
        }
    }

    /// The prepared entry INSERT, cached for the connection's lifetime: an index pass runs it
    /// hundreds of thousands of times, and re-preparing per batch is pure overhead.
    private var insertEntryStatement: OpaquePointer?

    private func insertEntries(_ records: [TranscriptRecord]) throws {
        guard !records.isEmpty else { return }
        let stmt: OpaquePointer
        if let cached = insertEntryStatement {
            stmt = cached
        } else {
            // Last-wins per D2, made order-independent: a response's usage only grows as it
            // streams, so a snapshot never replaces a larger one. Within a file that is the
            // same as last-wins; across files — forked subagent transcripts copy a request's
            // id together with an earlier snapshot of it — it stops the result depending on
            // which file the (parallel) pass happened to commit last.
            stmt = try prepare("""
            INSERT INTO entries
                (request_id, session_id, cwd, model, timestamp_ms,
                 input_tokens, output_tokens, cache_read_tokens,
                 ephemeral_5m_tokens, ephemeral_1h_tokens,
                 web_search, web_fetch, is_sidechain, billing)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(request_id) DO UPDATE SET
                session_id = excluded.session_id, cwd = excluded.cwd, model = excluded.model,
                timestamp_ms = excluded.timestamp_ms, input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens, cache_read_tokens = excluded.cache_read_tokens,
                ephemeral_5m_tokens = excluded.ephemeral_5m_tokens,
                ephemeral_1h_tokens = excluded.ephemeral_1h_tokens,
                web_search = excluded.web_search, web_fetch = excluded.web_fetch,
                is_sidechain = excluded.is_sidechain, billing = excluded.billing
            WHERE excluded.output_tokens >= entries.output_tokens;
            """)
            insertEntryStatement = stmt
        }
        for record in records {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, record.requestId)
            bindText(stmt, 2, record.sessionId)
            bindText(stmt, 3, record.cwd)
            bindText(stmt, 4, record.model)
            sqlite3_bind_int64(stmt, 5, Self.milliseconds(record.timestamp))
            sqlite3_bind_int64(stmt, 6, Int64(record.usage.input))
            sqlite3_bind_int64(stmt, 7, Int64(record.usage.output))
            sqlite3_bind_int64(stmt, 8, Int64(record.usage.cacheRead))
            sqlite3_bind_int64(stmt, 9, Int64(record.usage.ephemeral5m))
            sqlite3_bind_int64(stmt, 10, Int64(record.usage.ephemeral1h))
            sqlite3_bind_int64(stmt, 11, Int64(record.usage.webSearch))
            sqlite3_bind_int64(stmt, 12, Int64(record.usage.webFetch))
            sqlite3_bind_int64(stmt, 13, record.isSidechain ? 1 : 0)
            sqlite3_bind_int64(stmt, 14, Int64(record.billing.rawValue))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw TranscriptStoreError.stepFailed(rc, errMsg())
            }
        }
        sqlite3_reset(stmt)
    }

    /// Epoch milliseconds, rounded rather than truncated: a timestamp parsed from `…:01.123Z`
    /// is `1.123` in binary floating point, i.e. `1.12299…`, and truncation would store `…122`.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Returns all records whose `timestamp_ms` falls within `[start, end]` (inclusive).
    public func records(start: Date, end: Date) throws -> [TranscriptRecord] {
        let startMs = Self.milliseconds(start)
        let endMs = Self.milliseconds(end)
        let sql = entrySelectSQL + " WHERE timestamp_ms BETWEEN ? AND ? ORDER BY timestamp_ms ASC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startMs)
        sqlite3_bind_int64(stmt, 2, endMs)
        return try readRecords(stmt)
    }

    /// Returns all records in the store, ordered by timestamp ascending.
    public func allRecords() throws -> [TranscriptRecord] {
        let stmt = try prepare(entrySelectSQL + " ORDER BY timestamp_ms ASC;")
        defer { sqlite3_finalize(stmt) }
        return try readRecords(stmt)
    }

    private let entrySelectSQL = """
    SELECT request_id, session_id, cwd, model, timestamp_ms,
           input_tokens, output_tokens, cache_read_tokens,
           ephemeral_5m_tokens, ephemeral_1h_tokens,
           web_search, web_fetch, is_sidechain, billing
    FROM entries
    """

    private func readRecords(_ stmt: OpaquePointer) throws -> [TranscriptRecord] {
        var out: [TranscriptRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let requestId = columnText(stmt, 0)
                let sessionId = columnText(stmt, 1)
                let cwd = columnText(stmt, 2)
                let model = columnText(stmt, 3)
                let timestampMs = sqlite3_column_int64(stmt, 4)
                let usage = TokenUsage(
                    input: Int(sqlite3_column_int64(stmt, 5)),
                    output: Int(sqlite3_column_int64(stmt, 6)),
                    cacheRead: Int(sqlite3_column_int64(stmt, 7)),
                    ephemeral5m: Int(sqlite3_column_int64(stmt, 8)),
                    ephemeral1h: Int(sqlite3_column_int64(stmt, 9)),
                    webSearch: Int(sqlite3_column_int64(stmt, 10)),
                    webFetch: Int(sqlite3_column_int64(stmt, 11))
                )
                let isSidechain = sqlite3_column_int64(stmt, 12) != 0
                out.append(TranscriptRecord(
                    requestId: requestId,
                    sessionId: sessionId,
                    cwd: cwd,
                    model: model,
                    timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000.0),
                    usage: usage,
                    isSidechain: isSidechain,
                    billing: BillingModifiers(rawValue: Int(sqlite3_column_int64(stmt, 13)))
                ))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw TranscriptStoreError.stepFailed(rc, errMsg())
            }
        }
        return out
    }

    // MARK: - File state

    /// Inserts or replaces the persisted index state for a file.
    public func upsertFileState(_ state: FileIndexState) throws {
        let sql = """
        INSERT OR REPLACE INTO file_state
            (path, last_byte_offset, last_known_size, inode, device, last_event_id)
        VALUES (?,?,?,?,?,?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, state.path)
        sqlite3_bind_int64(stmt, 2, Int64(bitPattern: state.lastByteOffset))
        sqlite3_bind_int64(stmt, 3, Int64(bitPattern: state.lastKnownSize))
        sqlite3_bind_int64(stmt, 4, Int64(bitPattern: state.inode))
        sqlite3_bind_int64(stmt, 5, Int64(bitPattern: state.device))
        sqlite3_bind_int64(stmt, 6, Int64(bitPattern: state.lastEventId))
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }
    }

    /// Returns the persisted index state for `path`, or `nil` when none exists.
    public func fileState(path: String) throws -> FileIndexState? {
        let sql = """
        SELECT path, last_byte_offset, last_known_size, inode, device, last_event_id
        FROM file_state WHERE path = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return FileIndexState(
                path: columnText(stmt, 0),
                lastByteOffset: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)),
                lastKnownSize: UInt64(bitPattern: sqlite3_column_int64(stmt, 2)),
                inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 3)),
                device: UInt64(bitPattern: sqlite3_column_int64(stmt, 4)),
                lastEventId: UInt64(bitPattern: sqlite3_column_int64(stmt, 5))
            )
        } else if rc == SQLITE_DONE {
            return nil
        } else {
            throw TranscriptStoreError.stepFailed(rc, errMsg())
        }
    }

    /// Every persisted file state, keyed by path — one query for the launch catch-up
    /// instead of one per file.
    public func allFileStates() throws -> [String: FileIndexState] {
        let stmt = try prepare("""
        SELECT path, last_byte_offset, last_known_size, inode, device, last_event_id
        FROM file_state;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [String: FileIndexState] = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let state = FileIndexState(
                    path: columnText(stmt, 0),
                    lastByteOffset: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)),
                    lastKnownSize: UInt64(bitPattern: sqlite3_column_int64(stmt, 2)),
                    inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 3)),
                    device: UInt64(bitPattern: sqlite3_column_int64(stmt, 4)),
                    lastEventId: UInt64(bitPattern: sqlite3_column_int64(stmt, 5))
                )
                out[state.path] = state
            } else if rc == SQLITE_DONE {
                return out
            } else {
                throw TranscriptStoreError.stepFailed(rc, errMsg())
            }
        }
    }

    // MARK: - Codex parse context

    public func upsertCodexContext(_ context: CodexParseContext, path: String) throws {
        let stmt = try prepare("""
        INSERT OR REPLACE INTO codex_parse_context
            (path, session_id, cwd, model, ordinal, saw_usage_record, last_count_total)
        VALUES (?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        bindText(stmt, 2, context.sessionID)
        bindText(stmt, 3, context.cwd)
        bindText(stmt, 4, context.model)
        sqlite3_bind_int64(stmt, 5, Int64(context.ordinal))
        sqlite3_bind_int64(stmt, 6, context.sawUsageRecord ? 1 : 0)
        sqlite3_bind_int64(stmt, 7, Int64(context.lastCountTotal))
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }
    }

    /// Every persisted Codex parse context, keyed by rollout path.
    public func allCodexContexts() throws -> [String: CodexParseContext] {
        let stmt = try prepare("""
        SELECT path, session_id, cwd, model, ordinal, saw_usage_record, last_count_total
        FROM codex_parse_context;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [String: CodexParseContext] = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out[columnText(stmt, 0)] = CodexParseContext(
                    sessionID: columnText(stmt, 1),
                    cwd: columnText(stmt, 2),
                    model: columnText(stmt, 3),
                    ordinal: Int(sqlite3_column_int64(stmt, 4)),
                    sawUsageRecord: sqlite3_column_int64(stmt, 5) != 0,
                    lastCountTotal: Int(sqlite3_column_int64(stmt, 6))
                )
            } else if rc == SQLITE_DONE {
                return out
            } else {
                throw TranscriptStoreError.stepFailed(rc, errMsg())
            }
        }
    }

    /// Forgets every file's read position (not its records), so the next catch-up re-reads
    /// every transcript from the start. Records are keyed by request id, so re-reading
    /// replaces rather than duplicates them.
    public func resetReadPositions() throws {
        try inTransaction {
            try exec("DELETE FROM file_state;")
            try exec("DELETE FROM codex_parse_context;")
        }
    }

    // MARK: - Meta

    /// Stores a string value under `key` in the meta table.
    public func setMeta(key: String, value: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }
    }

    /// Returns the meta value for `key`, or `nil` when absent.
    public func getMeta(key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return columnText(stmt, 0)
        } else if rc == SQLITE_DONE {
            return nil
        } else {
            throw TranscriptStoreError.stepFailed(rc, errMsg())
        }
    }

    // MARK: - Binding helpers

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
}

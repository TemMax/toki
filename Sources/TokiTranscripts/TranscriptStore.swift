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
        // No per-call mutex: the owner already serialises the connection (see the type's
        // documentation), and SQLite's own lock around every `step` and `column_*` call was
        // 8% of the speed query's time per row.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
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
            last_event_id INTEGER NOT NULL,
            last_input_ms INTEGER,
            open_request_id TEXT,
            open_request_start_ms INTEGER
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
            billing INTEGER NOT NULL DEFAULT 0,
            generation_ms INTEGER,
            effort TEXT,
            fast INTEGER NOT NULL DEFAULT 0
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
            last_count_total INTEGER NOT NULL DEFAULT 0,
            anchor_ms INTEGER,
            effort TEXT,
            fast INTEGER NOT NULL DEFAULT 0
        );
        """)

        // Columns added after a table first shipped: `CREATE TABLE IF NOT EXISTS` leaves an
        // existing table as it was, so an older index gets them here.
        try addColumnIfMissing("entries", "billing INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("codex_parse_context", "saw_usage_record INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("codex_parse_context", "last_count_total INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("entries", "generation_ms INTEGER")
        try addColumnIfMissing("entries", "effort TEXT")
        try addColumnIfMissing("entries", "fast INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("file_state", "last_input_ms INTEGER")
        try addColumnIfMissing("file_state", "open_request_id TEXT")
        try addColumnIfMissing("file_state", "open_request_start_ms INTEGER")
        try addColumnIfMissing("codex_parse_context", "anchor_ms INTEGER")
        try addColumnIfMissing("codex_parse_context", "effort TEXT")
        try addColumnIfMissing("codex_parse_context", "fast INTEGER NOT NULL DEFAULT 0")

        // Serves `speedSamples()` alone: partial, so it holds only measurable rows, and in the
        // report's order, so the query needs neither the table nor a sort. `speedSamplesSQL`
        // repeats `speedIndexPredicate` verbatim, or SQLite will not use it. Its name carries
        // every limit, so a changed limit drops the old index and builds the new one, instead
        // of leaving `INDEXED BY` naming an index whose `WHERE` the query no longer implies.
        try dropSpeedIndexes(except: Self.speedIndexName)
        try exec("""
        CREATE INDEX IF NOT EXISTS \(Self.speedIndexName)
        ON entries(model, effort, fast, timestamp_ms, output_tokens, generation_ms)
        WHERE \(Self.speedIndexPredicate);
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    /// The speed index, named after the limits it was built with.
    static let speedIndexName = """
    idx_entries_speed_\(SpeedSampleFilter.minOutputTokens)_\
    \(SpeedSampleFilter.minGenerationMs)_\(SpeedSampleFilter.maxGenerationMs)
    """

    /// Which rows the speed index holds. The speed query's `WHERE` is exactly this, so the
    /// query implies the index's `WHERE` and SQLite need not re-test these terms per row.
    static let speedIndexPredicate = """
    generation_ms IS NOT NULL AND output_tokens >= \(SpeedSampleFilter.minOutputTokens) \
    AND generation_ms > \(SpeedSampleFilter.minGenerationMs) \
    AND generation_ms <= \(SpeedSampleFilter.maxGenerationMs)
    """

    /// Drops every speed index but `keep`: one built for other limits (or before the name
    /// carried them).
    private func dropSpeedIndexes(except keep: String) throws {
        var stale: [String] = []
        do {
            let stmt = try prepare("""
            SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_entries_speed%';
            """)
            defer { sqlite3_finalize(stmt) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }
                let name = columnText(stmt, 0)
                if name != keep { stale.append(name) }
            }
        }
        for name in stale {
            try exec("DROP INDEX IF EXISTS \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\";")
        }
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
            // Duration follows the usage rule above, with two additions that keep it
            // order-independent: a snapshot with no anchor never erases a measured duration,
            // and between snapshots of the same size the longer one wins — a request whose
            // blocks straddle two catch-up reads is re-measured to its later last block.
            stmt = try prepare("""
            INSERT INTO entries
                (request_id, session_id, cwd, model, timestamp_ms,
                 input_tokens, output_tokens, cache_read_tokens,
                 ephemeral_5m_tokens, ephemeral_1h_tokens,
                 web_search, web_fetch, is_sidechain, billing,
                 generation_ms, effort, fast)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(request_id) DO UPDATE SET
                session_id = excluded.session_id, cwd = excluded.cwd, model = excluded.model,
                timestamp_ms = excluded.timestamp_ms, input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens, cache_read_tokens = excluded.cache_read_tokens,
                ephemeral_5m_tokens = excluded.ephemeral_5m_tokens,
                ephemeral_1h_tokens = excluded.ephemeral_1h_tokens,
                web_search = excluded.web_search, web_fetch = excluded.web_fetch,
                is_sidechain = excluded.is_sidechain, billing = excluded.billing,
                generation_ms = CASE
                    WHEN excluded.generation_ms IS NULL THEN entries.generation_ms
                    WHEN entries.generation_ms IS NULL THEN excluded.generation_ms
                    WHEN excluded.output_tokens > entries.output_tokens THEN excluded.generation_ms
                    ELSE MAX(excluded.generation_ms, entries.generation_ms)
                END,
                effort = COALESCE(excluded.effort, entries.effort),
                fast = excluded.fast
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
            if let ms = record.generationMs {
                sqlite3_bind_int64(stmt, 15, Int64(ms))
            } else {
                sqlite3_bind_null(stmt, 15)
            }
            if let effort = record.effort { bindText(stmt, 16, effort) } else { sqlite3_bind_null(stmt, 16) }
            sqlite3_bind_int64(stmt, 17, record.isFast ? 1 : 0)

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

    static let speedSamplesSQL = """
    SELECT model, effort, fast, timestamp_ms, output_tokens, generation_ms
    FROM entries INDEXED BY \(speedIndexName)
    WHERE \(speedIndexPredicate)
    ORDER BY model, effort, fast, timestamp_ms;
    """

    /// Every measurable request, as columns, in group-then-time order: one statement over the
    /// speed index, so one snapshot without a transaction. Rows arrive grouped; each row's
    /// group columns are compared with the previous row's bytes where SQLite holds them, and a
    /// `String` is made only when the group changes.
    public func speedSamples() throws -> SpeedSamples {
        var out = SpeedSamples.empty
        let stmt = try prepare(Self.speedSamplesSQL)
        defer { sqlite3_finalize(stmt) }

        // The current group's key, copied out of SQLite once per group.
        var model: [UInt8] = []
        var effort: [UInt8]? = nil
        var fast: Int64 = 0
        var index: UInt16 = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }

            // `_text` before `_bytes`, as SQLite asks; a NULL value has a nil pointer.
            let modelText = sqlite3_column_text(stmt, 0)
            let modelCount = Int(sqlite3_column_bytes(stmt, 0))
            let effortText = sqlite3_column_text(stmt, 1)
            let effortCount = Int(sqlite3_column_bytes(stmt, 1))
            let rowFast = sqlite3_column_int64(stmt, 2)
            if out.groups.isEmpty || rowFast != fast
                || !Self.bytes(modelText, modelCount, equal: model)
                || !Self.bytes(effortText, effortCount, equal: effort) {
                model = Self.copy(modelText, modelCount) ?? []
                effort = Self.copy(effortText, effortCount)
                fast = rowFast
                index = UInt16(clamping: out.groups.count)
                out.groups.append(SpeedSampleGroup(
                    model: String(decoding: model, as: UTF8.self),
                    effort: effort.map { String(decoding: $0, as: UTF8.self) },
                    isFast: rowFast != 0))
            }
            out.group.append(index)
            out.timestampMs.append(sqlite3_column_int64(stmt, 3))
            out.outputTokens.append(Int32(clamping: sqlite3_column_int64(stmt, 4)))
            out.generationMs.append(Int32(clamping: sqlite3_column_int64(stmt, 5)))
        }
        return out
    }

    /// Whether a column's bytes (`nil` for NULL) equal `key` (`nil` for NULL).
    private static func bytes(_ text: UnsafePointer<UInt8>?, _ count: Int, equal key: [UInt8]?) -> Bool {
        guard let text, let key else { return text == nil && key == nil }
        guard count == key.count else { return false }
        if count == 0 { return true }
        return key.withUnsafeBufferPointer { memcmp(text, $0.baseAddress, count) == 0 }
    }

    private static func copy(_ text: UnsafePointer<UInt8>?, _ count: Int) -> [UInt8]? {
        text.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
    }

    private let entrySelectSQL = """
    SELECT request_id, session_id, cwd, model, timestamp_ms,
           input_tokens, output_tokens, cache_read_tokens,
           ephemeral_5m_tokens, ephemeral_1h_tokens,
           web_search, web_fetch, is_sidechain, billing,
           generation_ms, effort, fast
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
                    billing: BillingModifiers(rawValue: Int(sqlite3_column_int64(stmt, 13))),
                    generationMs: sqlite3_column_type(stmt, 14) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(stmt, 14)),
                    effort: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : columnText(stmt, 15),
                    isFast: sqlite3_column_int64(stmt, 16) != 0
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
            (path, last_byte_offset, last_known_size, inode, device, last_event_id, last_input_ms,
             open_request_id, open_request_start_ms)
        VALUES (?,?,?,?,?,?,?,?,?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, state.path)
        sqlite3_bind_int64(stmt, 2, Int64(bitPattern: state.lastByteOffset))
        sqlite3_bind_int64(stmt, 3, Int64(bitPattern: state.lastKnownSize))
        sqlite3_bind_int64(stmt, 4, Int64(bitPattern: state.inode))
        sqlite3_bind_int64(stmt, 5, Int64(bitPattern: state.device))
        sqlite3_bind_int64(stmt, 6, Int64(bitPattern: state.lastEventId))
        if let ms = state.lastInputMs { sqlite3_bind_int64(stmt, 7, ms) } else { sqlite3_bind_null(stmt, 7) }
        if let id = state.openRequestId { bindText(stmt, 8, id) } else { sqlite3_bind_null(stmt, 8) }
        if let ms = state.openRequestStartMs { sqlite3_bind_int64(stmt, 9, ms) } else { sqlite3_bind_null(stmt, 9) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }
    }

    /// Returns the persisted index state for `path`, or `nil` when none exists.
    public func fileState(path: String) throws -> FileIndexState? {
        let sql = """
        SELECT path, last_byte_offset, last_known_size, inode, device, last_event_id, last_input_ms,
               open_request_id, open_request_start_ms
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
                lastEventId: UInt64(bitPattern: sqlite3_column_int64(stmt, 5)),
                lastInputMs: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6),
                openRequestId: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : columnText(stmt, 7),
                openRequestStartMs: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
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
        SELECT path, last_byte_offset, last_known_size, inode, device, last_event_id, last_input_ms,
               open_request_id, open_request_start_ms
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
                    lastEventId: UInt64(bitPattern: sqlite3_column_int64(stmt, 5)),
                lastInputMs: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 6),
                openRequestId: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : columnText(stmt, 7),
                openRequestStartMs: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
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
            (path, session_id, cwd, model, ordinal, saw_usage_record, last_count_total,
             anchor_ms, effort, fast)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        bindText(stmt, 2, context.sessionID)
        bindText(stmt, 3, context.cwd)
        bindText(stmt, 4, context.model)
        sqlite3_bind_int64(stmt, 5, Int64(context.ordinal))
        sqlite3_bind_int64(stmt, 6, context.sawUsageRecord ? 1 : 0)
        sqlite3_bind_int64(stmt, 7, Int64(context.lastCountTotal))
        if let ms = context.anchorMs { sqlite3_bind_int64(stmt, 8, ms) } else { sqlite3_bind_null(stmt, 8) }
        if let effort = context.effort { bindText(stmt, 9, effort) } else { sqlite3_bind_null(stmt, 9) }
        sqlite3_bind_int64(stmt, 10, context.isFast ? 1 : 0)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw TranscriptStoreError.stepFailed(rc, errMsg()) }
    }

    /// Every persisted Codex parse context, keyed by rollout path.
    public func allCodexContexts() throws -> [String: CodexParseContext] {
        let stmt = try prepare("""
        SELECT path, session_id, cwd, model, ordinal, saw_usage_record, last_count_total,
               anchor_ms, effort, fast
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
                    lastCountTotal: Int(sqlite3_column_int64(stmt, 6)),
                    anchorMs: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7),
                    effort: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : columnText(stmt, 8),
                    isFast: sqlite3_column_int64(stmt, 9) != 0
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

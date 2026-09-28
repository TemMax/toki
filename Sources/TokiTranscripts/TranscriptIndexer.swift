/// TranscriptIndexer — incremental JSONL parsing and SQLite index for transcript records.
import Foundation
import TokiLogging
import TokiModels

private let log = TokiLog.logger("transcripts")

/// Scans `~/.claude/projects/**/*.jsonl` (excluding `journal.jsonl`) for `type=="assistant"`
/// records, deduplicates by `requestId` (last-wins per D2), and persists results to a SQLite
/// database at `~/Library/Application Support/Toki/index.sqlite3`.
///
/// Every file's read position is persisted, so both the launch catch-up (`reindex()`) and the
/// `FSEventStream` watcher only ever read what was appended since the last pass. The actor owns
/// the write connection and all mutable state; reads use a separate connection (`IndexReader`).
public actor TranscriptIndexer: RecordProviding {
    /// The opened SQLite store, or `nil` until a lazy open succeeds.
    /// All store-dependent paths route through `requireStore()`.
    private var store: TranscriptStore?
    /// The deferred database URL, opened lazily on first store access (non-throwing init path).
    private let databaseURL: URL?
    /// The read side's own connection (see `allRecords()`).
    private let reader: IndexReader
    private let projectsDirectory: URL?
    private var watcher: DirectoryWatcher?
    private let codexSessionsDirectory: URL?
    private var codexWatcher: DirectoryWatcher?

    /// Codex moves completed rollouts beside `sessions`, into `archived_sessions`.
    /// Both locations are one history source: omitting the archive makes older activity
    /// disappear from a full rebuild even though the files are still on disk.
    private var codexArchivedSessionsDirectory: URL? {
        codexSessionsDirectory?.deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    /// Fired (debounced) after the index changes, so a consumer (the dashboard) can
    /// reload analytics live as Claude Code writes new transcript records. Set via
    /// `setOnIndexChanged(_:)`.
    private var onIndexChanged: (@Sendable () async -> Void)?
    /// Trailing-debounce task that coalesces a burst of file changes into a single
    /// notification, so rapid writes during an active session trigger one reload.
    private var changeNotifyTask: Task<Void, Never>?
    /// Debounce window for the change notification. FSEvents already coalesces raw
    /// events to ~0.5s batches; this adds a 1s trailing window on top.
    ///
    /// Injectable because it was not, and that made the two tests around it race the clock:
    /// they slept a fixed 1.3s against this 1s window, leaving 300ms of slack for a `Task` to
    /// be scheduled and run. That slack held when the suite ran alone and vanished under the
    /// full parallel suite, so the tests failed for load rather than for behaviour. A test
    /// can now pick a short window and wait for the condition instead of for the clock.
    static let defaultChangeNotifyDelayNanos: UInt64 = 1_000_000_000
    private let changeNotifyDelayNanos: UInt64

    /// Meta key under which the highest processed FSEvent id is persisted.
    private static let lastEventIdKey = "last_fsevent_id"
    private static let codexLastEventIdKey = "codex_last_fsevent_id"

    /// - Parameter databaseURL: SQLite index location. Defaults to
    ///   `~/Library/Application Support/Toki/index.sqlite3`.
    ///
    /// This init is non-throwing per the module contract and is resilient: it does NOT open
    /// the SQLite store eagerly (so merely constructing an indexer never touches the filesystem
    /// nor creates `~/Library/Application Support/Toki`). The store is opened lazily on first
    /// store-dependent call. If that open fails, throwing methods (`reindex`, `records`) rethrow
    /// the failure as `TokiError.decoding`, and the non-throwing `allRecords()` returns `[]`.
    public init(
        databaseURL: URL? = nil,
        claudeProjectsDirectory: URL? = TranscriptIndexer.defaultProjectsDirectory(),
        codexSessionsDirectory: URL? = TranscriptIndexer.defaultCodexSessionsDirectory()
    ) {
        self.store = nil
        self.databaseURL = databaseURL
        self.reader = IndexReader(databaseURL: databaseURL ?? TranscriptStore.defaultDatabaseURL())
        self.projectsDirectory = claudeProjectsDirectory
        self.codexSessionsDirectory = codexSessionsDirectory
        self.changeNotifyDelayNanos = Self.defaultChangeNotifyDelayNanos
    }

    /// Test-only / advanced init allowing a custom projects directory. Opens the store eagerly
    /// (and therefore throws) so tests fail fast on a bad temp DB.
    init(
        databaseURL: URL,
        projectsDirectory: URL,
        codexSessionsDirectory: URL? = nil,
        changeNotifyDelayNanos: UInt64 = TranscriptIndexer.defaultChangeNotifyDelayNanos
    ) throws {
        self.store = try TranscriptStore(databaseURL: databaseURL)
        self.databaseURL = databaseURL
        self.reader = IndexReader(databaseURL: databaseURL)
        self.projectsDirectory = projectsDirectory
        self.codexSessionsDirectory = codexSessionsDirectory
        self.changeNotifyDelayNanos = changeNotifyDelayNanos
    }

    /// Returns the opened store, lazily opening it on first use. Throws `TokiError.decoding`
    /// (with a diagnostic) when the open fails, so callers never crash on a misconfigured store.
    /// A failed open is retried on the next call rather than remembered for the session.
    private func requireStore() throws -> TranscriptStore {
        if let store { return store }
        let url = databaseURL ?? TranscriptStore.defaultDatabaseURL()
        do {
            let opened = try TranscriptStore(databaseURL: url)
            self.store = opened
            return opened
        } catch {
            log.error("failed to open transcript store \(error: error)")
            throw TokiError.decoding("TranscriptIndexer: failed to open SQLite store: \(error)")
        }
    }

    /// Best-effort store access for non-throwing paths; returns `nil` when the open failed.
    private func optionalStore() -> TranscriptStore? {
        // no-log: the underlying open failure (if any) was already logged above, in
        // requireStore()'s catch.
        try? requireStore()
    }

    public static func defaultProjectsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    public static func defaultCodexSessionsDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    // MARK: - Catch-up

    /// Brings the index up to date with every transcript on disk.
    ///
    /// Incremental, not a rebuild: each file's read position is persisted, so a file that has
    /// not changed since the last pass is skipped after one `stat`, and one that grew is read
    /// from where the last pass stopped. On a normal launch that is a few appended files, not
    /// the whole multi-gigabyte archive. Only a file that was replaced or truncated — or every
    /// file, when `indexFormatVersion` changes — is read from the start.
    ///
    /// Changed files are parsed in parallel (newest first, so recent ranges fill in first on a
    /// cold build) and committed in batches as they finish; `setOnProgress` hears about each
    /// batch, which is what lets the dashboard fill in progressively instead of waiting for
    /// the last file. Reads never wait for this: they go through a separate connection.
    ///
    /// Concurrent calls coalesce: a call made while a pass runs waits for it, and that pass
    /// is then repeated once so nothing that changed mid-pass is missed.
    public func reindex() async throws {
        if let running = catchUpTask {
            catchUpAgain = true
            try await running.value
            return
        }
        // `runCatchUps` clears `catchUpTask` itself, in the same actor turn as its last check
        // for deferred work — clearing it here, after resuming, would leave a window where a
        // watcher batch is deferred to a pass that has already finished.
        let task = Task { try await self.runCatchUps() }
        catchUpTask = task
        try await task.value
    }

    /// Bump when parsing changes what a line produces, so existing indexes re-read every
    /// file once. Version 2: the parallel byte-level catch-up (earlier indexes could hold a
    /// read position past a line that was still being written). Version 3: Claude billing
    /// modifiers (fast mode, US-only inference) and Codex `token_count` fallback usage.
    static let indexFormatVersion = "3"
    private static let indexFormatKey = "index_format"

    /// The in-flight catch-up, shared by concurrent callers.
    private var catchUpTask: Task<Void, Error>?
    /// A catch-up was requested while one ran.
    private var catchUpAgain = false
    /// Watcher batches that arrived during a catch-up, replayed right after it.
    private var deferredClaudePaths: Set<String> = []
    private var deferredCodexPaths: Set<String> = []

    /// Runs passes until none is owed, then replays the watcher batches deferred meanwhile —
    /// looping, because more can be deferred (or another pass requested) during the replay.
    private func runCatchUps() async throws {
        var passOwed = true
        while true {
            if passOwed || catchUpAgain {
                passOwed = false
                catchUpAgain = false
                do {
                    try await performCatchUp()
                } catch {
                    // performCatchUp logged the cause; this records that the pass is abandoned.
                    log.notice("catch-up abandoned \(error: error)")
                    catchUpTask = nil
                    throw error
                }
                continue
            }
            let claude = deferredClaudePaths
            let codex = deferredCodexPaths
            guard !claude.isEmpty || !codex.isEmpty else {
                catchUpTask = nil
                return
            }
            deferredClaudePaths = []
            deferredCodexPaths = []
            await ingest(paths: claude, kind: .claude)
            await ingest(paths: codex, kind: .codex)
        }
    }

    private func performCatchUp() async throws {
        let store = try requireStore()
        let start = Date()
        if try store.getMeta(key: Self.indexFormatKey) != Self.indexFormatVersion {
            log.info("index format changed, re-reading every transcript")
            try store.resetReadPositions()
            try store.setMeta(key: Self.indexFormatKey, value: Self.indexFormatVersion)
        }
        let states = try store.allFileStates()
        let contexts = try store.allCodexContexts()

        let claudeFiles = projectsDirectory.map { jsonlFiles(under: $0) } ?? []
        let codexFiles = [codexSessionsDirectory, codexArchivedSessionsDirectory]
            .compactMap { $0 }
            .flatMap { jsonlFiles(under: $0) }
        var jobs = claudeFiles.compactMap { ScanJob.make(path: $0.path, kind: .claude, prior: states[$0.path]) }
        jobs += codexFiles.compactMap {
            ScanJob.make(path: $0.path, kind: .codex, prior: states[$0.path], context: contexts[$0.path])
        }
        // Newest first: on a cold build, today's and this week's numbers are complete long
        // before last quarter's are.
        jobs.sort { $0.modified > $1.modified }

        let scanned = claudeFiles.count + codexFiles.count
        log.info("catch-up starting: \(jobs.count) of \(scanned) files changed")
        do {
            try await run(jobs, store: store, reportsProgress: true)
        } catch {
            log.error("catch-up failed after \(Date().timeIntervalSince(start))s \(error: error)")
            throw error
        }
        log.info("catch-up finished: \(jobs.count) of \(scanned) files read in \(Date().timeIntervalSince(start))s")
    }

    /// Parses `jobs` concurrently and commits the results in batches.
    ///
    /// Parsing is the expensive part and is independent per file, so it fans out across the
    /// cores; writing stays on this actor (one SQLite connection), batched so a cold build is a
    /// few hundred transactions rather than one per file. A file that cannot be read (deleted
    /// mid-pass, permissions) is logged and skipped; a store failure aborts the pass.
    private func run(_ jobs: [ScanJob], store: TranscriptStore, reportsProgress: Bool) async throws {
        guard !jobs.isEmpty else {
            if reportsProgress { await report(IndexProgress(filesDone: 0, filesTotal: 0)) }
            return
        }
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        var pending: [IndexedFile] = []
        var pendingRecords = 0
        var done = 0
        var lastFlush = ContinuousClock.now

        func flush() async throws {
            guard !pending.isEmpty else { return }
            try store.apply(pending)
            pending.removeAll(keepingCapacity: true)
            pendingRecords = 0
            lastFlush = .now
            if reportsProgress {
                await report(IndexProgress(filesDone: done, filesTotal: jobs.count))
            }
        }

        try await withThrowingTaskGroup(of: IndexedFile?.self) { group in
            var next = 0
            while next < min(width, jobs.count) {
                let job = jobs[next]
                group.addTask { Self.scan(job) }
                next += 1
            }
            while let result = try await group.next() {
                done += 1
                if let result {
                    pendingRecords += result.records.count
                    pending.append(result)
                }
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask { Self.scan(job) }
                    next += 1
                }
                if pendingRecords >= 20_000 || pending.count >= 512
                    || ContinuousClock.now - lastFlush >= .milliseconds(250) {
                    try await flush()
                }
            }
            try await flush()
        }
    }

    /// Reads one file from its job's start offset. Runs off the actor, in parallel.
    private static func scan(_ job: ScanJob) -> IndexedFile? {
        do {
            switch job.kind {
            case .claude:
                var records: [TranscriptRecord] = []
                var slot: [String: Int] = [:]
                let result = try LineScanner.scan(path: job.path, from: job.startOffset) { line, _ in
                    guard let record = TranscriptParser.parse(bytes: line) else { return }
                    // Last-wins per requestId (D2): a streamed response is written several
                    // times with growing usage, and only its final line counts.
                    if let index = slot[record.requestId] {
                        records[index] = record
                    } else {
                        slot[record.requestId] = records.count
                        records.append(record)
                    }
                }
                return IndexedFile(records: records, state: job.state(after: result))
            case .codex:
                var scan = CodexScan(context: job.context)
                let result = try LineScanner.scan(path: job.path, from: job.startOffset) { line, isComplete in
                    scan.consume(line, isComplete: isComplete)
                }
                return IndexedFile(records: scan.finish(), state: job.state(after: result), codexContext: scan.context)
            }
        } catch {
            log.error("failed to read transcript file \(path: URL(fileURLWithPath: job.path)) \(error: error)")
            return nil
        }
    }

    // MARK: - Progress

    /// Registers a handler told about catch-up progress: once when a pass starts reading, after
    /// every committed batch, and with `isFinished` at the end. Replaces any previous handler.
    public func setOnProgress(_ handler: @escaping @Sendable (IndexProgress) async -> Void) {
        onProgress = handler
    }

    private var onProgress: (@Sendable (IndexProgress) async -> Void)?

    private func report(_ progress: IndexProgress) async {
        await onProgress?(progress)
    }

    // MARK: - Change notification

    /// Registers a handler invoked (debounced by ~1s) after the index changes, so the
    /// UI can reload analytics live. Replaces any previously-registered handler.
    public func setOnIndexChanged(_ handler: @escaping @Sendable () async -> Void) {
        self.onIndexChanged = handler
    }

    /// Schedules a debounced change notification: each call cancels the pending fire and
    /// restarts the window, so a burst of changes fires the handler once, ~1s after the last.
    private func scheduleChangeNotification() {
        guard onIndexChanged != nil else { return }
        changeNotifyTask?.cancel()
        // Read off the actor before entering the detached task — `self` is weak in there.
        let delay = changeNotifyDelayNanos
        changeNotifyTask = Task { [weak self] in
            // no-log: a `Task.sleep` failure here means the task was cancelled (a newer
            // change superseded this debounce window) — expected control flow, not a failure.
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.fireIndexChanged()
        }
    }

    private func fireIndexChanged() async {
        await onIndexChanged?()
    }

    /// Test hook: drives the debounce path directly without an FSEvent.
    func notifyChangeForTesting() {
        scheduleChangeNotification()
    }

    // MARK: - Watching

    /// Begins watching the projects directory via FSEvents for incremental updates.
    public func startWatching() async {
        guard watcher == nil, codexWatcher == nil else { return }

        if let projectsDirectory {
            let resumeId = optionalStore().flatMap { loadResumeId(from: $0) }

            let watcher = DirectoryWatcher(
                url: projectsDirectory,
                sinceWhen: resumeId,
                onChange: { [weak self] (changedPaths: [String]) in
                    guard let self else { return }
                    Task { await self.handleChangedFiles(changedPaths) }
                },
                onNeedsFullRescan: { [weak self] in
                    guard let self else { return }
                    // Kernel dropped events — perform a full reindex so no changes are missed.
                    Task { await self.handleFullRescanNeeded() }
                }
            )
            self.watcher = watcher
            watcher.start()
        }

        if let codexSessionsDirectory {
            let codexResume = optionalStore().flatMap {
                loadResumeId(from: $0, key: Self.codexLastEventIdKey)
            }
            // One recursive FSEvents stream on CODEX_HOME covers active and archived
            // rollouts, including the atomic move from one directory to the other.
            let watcher = DirectoryWatcher(
                url: codexSessionsDirectory.deletingLastPathComponent(),
                sinceWhen: codexResume,
                onChange: { [weak self] paths in
                    guard let self else { return }
                    Task { await self.handleCodexChangedFiles(paths) }
                },
                onNeedsFullRescan: { [weak self] in
                    guard let self else { return }
                    Task { await self.handleFullRescanNeeded() }
                }
            )
            codexWatcher = watcher
            watcher.start()
        }
    }

    /// Reads the persisted high-water FSEvent id to resume watching from, logging (rather
    /// than silently discarding) a genuine sqlite failure while still degrading to "start
    /// from now" either way.
    private func loadResumeId(from store: TranscriptStore) -> UInt64? {
        loadResumeId(from: store, key: Self.lastEventIdKey)
    }

    private func loadResumeId(from store: TranscriptStore, key: String) -> UInt64? {
        do {
            guard let value = try store.getMeta(key: key) else { return nil }
            return UInt64(value)
        } catch {
            log.error("failed to load resume event id \(error: error)")
            return nil
        }
    }

    /// Stops watching (if active).
    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        codexWatcher?.stop()
        codexWatcher = nil
        changeNotifyTask?.cancel()
        changeNotifyTask = nil
    }

    /// Processes a batch of changed Claude files: tail each from its read position, persist
    /// the records and positions, and persist the highest FSEvent id.
    private func handleChangedFiles(_ paths: [String]) async {
        guard let store = optionalStore() else { return }
        let transcripts = paths.filter { path in
            path.hasSuffix(".jsonl") && !path.hasSuffix("/journal.jsonl")
        }
        if catchUpTask != nil {
            // The running pass may already have stat'ed these files; replay them after it.
            deferredClaudePaths.formUnion(transcripts)
        } else {
            await ingest(paths: Set(transcripts), kind: .claude)
        }
        // Fix 3: Always persist the max event id, even when the batch contained no .jsonl
        // changes (e.g. control-flag batches, non-jsonl events). This ensures a relaunch
        // resumes from the correct position regardless of batch content.
        persistMaxEventId(to: store)
        scheduleChangeNotification()
    }

    private func handleCodexChangedFiles(_ paths: [String]) async {
        guard let store = optionalStore() else { return }
        let rollouts = paths.filter { path in
            path.hasSuffix(".jsonl") && isCodexRollout(URL(fileURLWithPath: path))
        }
        if catchUpTask != nil {
            deferredCodexPaths.formUnion(rollouts)
        } else {
            await ingest(paths: Set(rollouts), kind: .codex)
        }
        persistCodexMaxEventId(to: store)
        scheduleChangeNotification()
    }

    /// Reads the new part of each changed file — the same scan the catch-up runs, for just
    /// these paths. A Codex rollout resumes with its persisted parse context.
    private func ingest(paths: Set<String>, kind: SourceKind) async {
        guard !paths.isEmpty, let store = optionalStore() else { return }
        do {
            let contexts = kind == .codex ? try store.allCodexContexts() : [:]
            let jobs = try paths.compactMap { path in
                ScanJob.make(path: path, kind: kind, prior: try store.fileState(path: path), context: contexts[path])
            }
            try await run(jobs, store: store, reportsProgress: false)
        } catch {
            log.error("failed to index changed transcripts \(error: error)")
        }
    }

    private func isCodexRollout(_ url: URL) -> Bool {
        guard let sessions = codexSessionsDirectory else { return false }
        let path = url.standardizedFileURL.path
        let roots = [sessions, codexArchivedSessionsDirectory].compactMap { $0 }
        return roots.contains { root in
            path.hasPrefix(root.standardizedFileURL.path + "/")
        }
    }

    /// Triggered when FSEvents signals that events were dropped (MustScanSubDirs, UserDropped,
    /// KernelDropped, RootChanged). Runs a catch-up pass — which re-checks every file, so no
    /// .jsonl change is missed — then persists the current high-water event id.
    private func handleFullRescanNeeded() async {
        guard let store = optionalStore() else { return }
        // Best-effort: if the reindex fails, we try again next time; reindex() itself
        // already logs the start/finish/failure, so this only needs to keep going.
        do {
            try await reindex()
        } catch {
            log.error("full-rescan reindex failed \(error: error)")
        }
        // Fix 3: Also persist the max event id after a rescan so relaunch resumes correctly.
        persistMaxEventId(to: store)
        persistCodexMaxEventId(to: store)
        scheduleChangeNotification()
    }

    /// Persists the highest FSEvent id seen so far. Called after every batch (Fix 3).
    private func persistMaxEventId(to store: TranscriptStore) {
        if let watcher {
            let maxId = watcher.currentMaxEventId()
            do {
                try store.setMeta(key: Self.lastEventIdKey, value: String(maxId))
            } catch {
                log.error("failed to persist last fsevent id \(error: error)")
            }
        }
    }

    private func persistCodexMaxEventId(to store: TranscriptStore) {
        guard let codexWatcher else { return }
        do {
            try store.setMeta(
                key: Self.codexLastEventIdKey,
                value: String(codexWatcher.currentMaxEventId())
            )
        } catch {
            log.error("failed to persist Codex event id \(error: error)")
        }
    }

    // MARK: - RecordProviding

    /// Returns all deduplicated transcript records currently in the index.
    ///
    /// Reads go through `reader`, a connection of their own, and are `nonisolated`: a
    /// dashboard query never queues behind a catch-up that is writing on the actor, and
    /// SQLite's WAL lets it read everything committed so far while that pass continues.
    public nonisolated func allRecords() async -> [TranscriptRecord] {
        do {
            return try reader.read { try $0.allRecords() }
        } catch {
            log.error("failed to read all records \(error: error)")
            return []
        }
    }

    /// Returns deduplicated records whose timestamp falls in [start, end].
    public nonisolated func records(start: Date, end: Date) async throws -> [TranscriptRecord] {
        try reader.read { try $0.records(start: start, end: end) }
    }

    // MARK: - File enumeration

    /// Enumerates `*.jsonl` files under `directory` recursively, excluding `journal.jsonl`.
    private func jsonlFiles(under directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard url.lastPathComponent != "journal.jsonl" else { continue }
            out.append(url)
        }
        return out
    }
}

/// DirectoryWatcher — FSEvents-based recursive watcher for the Claude projects directory.
import Foundation
import CoreServices
import TokiLogging

private let log = TokiLog.logger("transcripts")

/// Watches a directory tree via a single `FSEventStream` and reports changed `.jsonl` files.
///
/// `@unchecked Sendable` justification: this type wraps a C `FSEventStreamRef` plus a small set of
/// fields. The C callback fires on the stream's dispatch queue; all mutable state touched from the
/// callback (`lastEventId`, the user `onChange` closure) is confined to that single serial queue,
/// and `start()`/`stop()` are also marshalled onto it. There is therefore no concurrent access to
/// the mutable fields, but the compiler cannot prove this through the C boundary — hence the
/// manual conformance.
public final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([String]) -> Void
    /// Called when the kernel signals that events were dropped or a full rescan is needed.
    /// The callee should trigger a full reindex() so no .jsonl changes are missed.
    private let onNeedsFullRescan: (@Sendable () -> Void)?

    private var stream: FSEventStreamRef?
    /// Highest event id observed; persist this to resume after relaunch.
    private var maxEventId: UInt64
    private let sinceWhen: FSEventStreamEventId

    /// - Parameters:
    ///   - url: directory to watch recursively (e.g. `~/.claude/projects`).
    ///   - sinceWhen: resume id from persisted `last_fsevent_id`, or `nil` to start from now.
    ///   - latency: coalescing latency in seconds (default 0.5s per R8).
    ///   - onChange: called with the list of changed `.jsonl` file paths.
    ///   - onNeedsFullRescan: called when the kernel drops events or signals a root change,
    ///     meaning incremental tracking is unreliable and a full reindex is required.
    public init(
        url: URL,
        sinceWhen: UInt64? = nil,
        latency: CFTimeInterval = 0.5,
        onChange: @escaping @Sendable ([String]) -> Void,
        onNeedsFullRescan: (@Sendable () -> Void)? = nil
    ) {
        self.url = url
        self.latency = latency
        self.onChange = onChange
        self.onNeedsFullRescan = onNeedsFullRescan
        self.queue = DispatchQueue(label: "dev.komar.toki.directorywatcher")
        self.sinceWhen = sinceWhen.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        self.maxEventId = sinceWhen ?? 0
    }

    /// Highest FSEvent id seen so far (thread-safe snapshot for persistence).
    public func currentMaxEventId() -> UInt64 {
        queue.sync { maxEventId }
    }

    /// Starts the FSEventStream. Idempotent.
    public func start() {
        queue.sync {
            guard stream == nil else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let flags = UInt32(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
            )

            let pathsToWatch = [url.path] as CFArray

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                eventCallback,
                &context,
                pathsToWatch,
                sinceWhen,
                latency,
                flags
            ) else {
                return
            }

            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    /// Stops and tears down the FSEventStream. Idempotent.
    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Test-only entry point that calls `handleEvents` synchronously on the watcher's queue.
    /// Named distinctly to make the test-only nature obvious at the call site.
    internal func handleEventsForTesting(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        ids: [FSEventStreamEventId]
    ) {
        queue.sync {
            handleEvents(paths: paths, flags: flags, ids: ids)
        }
    }

    // Fix 2: FSEvents control flags that indicate the kernel dropped or coalesced events.
    // When any of these appear we cannot rely on incremental tracking — a full rescan is needed.
    private static let rescanFlags: FSEventStreamEventFlags = UInt32(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
    )

    /// Invoked on `queue` from the C callback. Filters to changed `.jsonl` files and detects
    /// control flags that require a full rescan.
    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        var changed: [String] = []
        var needsRescan = false

        for index in paths.indices {
            let path = paths[index]
            let flag = flags[index]
            let id = ids[index]

            if UInt64(id) > maxEventId { maxEventId = UInt64(id) }

            // Fix 2: Check for kernel-level drop/coalesce flags before any path filtering.
            if (flag & Self.rescanFlags) != 0 {
                needsRescan = true
            }

            guard path.hasSuffix(".jsonl") else { continue }

            let isRelevant =
                (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                || (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                || (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
            guard isRelevant else { continue }

            changed.append(path)
        }

        // Fix 3: Persist the high-water event id even when no .jsonl files were present in
        // this batch (e.g. control-flag-only batches or non-jsonl file events). The watcher
        // exposes the updated maxEventId via currentMaxEventId() which the indexer reads after
        // each callback. Since we've already updated maxEventId above, any subsequent call to
        // currentMaxEventId() will return the correct value for persistence.

        // Logged once per callback (a whole FSEvents batch), never per path in the loop
        // above — a batch is already coalesced by the kernel, so this cannot flood.
        log.debug("watcher event: \(paths.count) raw, \(changed.count) relevant, rescanNeeded=\(needsRescan)")

        if needsRescan {
            onNeedsFullRescan?()
        }
        if !changed.isEmpty {
            onChange(changed)
        }
    }
}

/// C callback trampoline. `clientCallBackInfo` carries the `DirectoryWatcher` (unretained).
private func eventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()

    // With UseCFTypes, eventPaths is a CFArray of CFString.
    let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
    let cfCount = CFArrayGetCount(cfArray)

    // Fix 4: Guard that both counts agree. numEvents drives the flags/ids pointer arrays;
    // cfCount drives the CFArray. Use the minimum to avoid out-of-bounds indexing if the
    // C layer ever delivers mismatched values.
    let safeCount = min(numEvents, cfCount)
    guard safeCount > 0 else { return }

    var paths: [String] = []
    paths.reserveCapacity(safeCount)
    for i in 0..<safeCount {
        let ptr = CFArrayGetValueAtIndex(cfArray, i)
        let cfString = unsafeBitCast(ptr, to: CFString.self)
        paths.append(cfString as String)
    }

    var flags: [FSEventStreamEventFlags] = []
    var ids: [FSEventStreamEventId] = []
    flags.reserveCapacity(safeCount)
    ids.reserveCapacity(safeCount)
    for i in 0..<safeCount {
        flags.append(eventFlags[i])
        ids.append(eventIds[i])
    }

    watcher.handleEvents(paths: paths, flags: flags, ids: ids)
}

import Foundation
import TokiLogging

/// Polls a provider's public Statuspage-compatible API with conditional GETs.
///
/// `status.json` (216 bytes) is the cheap change signal; `summary.json` (~7 KB) is fetched
/// only when the signal moved by default. OpenAI polls the summary directly because
/// its component changes need not move the page-wide indicator. Both routes carry ETags — a 304 costs zero bytes of body. Polling
/// every 30–60 s all day is only defensible because of that pair, so the ETags are held here
/// rather than delegated to `URLCache`: a shared disk cache can be evicted, shared with other
/// requests, or answer a request from stale bytes without us knowing.
///
/// An actor because the two stored ETags are mutable state read and written across polls.
public actor ServiceStatusClient {
    private let session: URLSession
    private let baseURL: URL
    private let componentNames: Set<String>
    private let incidentTitleKeywords: Set<String>
    private let pollsSummaryDirectly: Bool
    private let log = TokiLog.logger("status")

    private var statusETag: String?
    private var summaryETag: String?

    public init(
        session: URLSession = ServiceStatusClient.makeDefaultSession(),
        baseURL: URL = URL(string: "https://status.claude.com")!,
        componentNames: Set<String> = [StatusParser.claudeCodeComponentName],
        incidentTitleKeywords: Set<String> = [],
        pollsSummaryDirectly: Bool = false
    ) {
        self.session = session
        self.baseURL = baseURL
        self.componentNames = componentNames
        self.incidentTitleKeywords = incidentTitleKeywords
        self.pollsSummaryDirectly = pollsSummaryDirectly
    }

    /// One poll step. Returns the freshly parsed status, or nil when nothing changed (304)
    /// or the page was unreachable — the caller keeps its last known value.
    ///
    /// Never throws and never surfaces an error to the caller: the status page being down is
    /// not the user's problem, and a status monitor that itself reports errors to the UI is
    /// noise on top of noise. It does emit diagnostic-only logging (request outcome, ETag
    /// hits, transport/decode failures) to the "status" log for support debugging — that
    /// never reaches the user and never changes what `poll()` returns.
    public func poll() async -> ServiceStatus? {
        // OpenAI's page-wide indicator can stay unchanged while individual Codex
        // components or incident updates change. Its summary ETag is the change signal.
        if pollsSummaryDirectly {
            guard let summary = await fetch(path: "/api/v2/summary.json", etag: summaryETag) else { return nil }
            switch summary {
            case .notModified: return nil
            case let .body(data, etag):
                do {
                    let status = try StatusParser.serviceStatus(
                        fromSummary: data, componentNames: componentNames,
                        incidentTitleKeywords: incidentTitleKeywords
                    )
                    summaryETag = etag
                    return status
                } catch {
                    log.error("Direct status summary rejected \(error: error)")
                    return nil
                }
            }
        }
        guard let signal = await fetch(path: "/api/v2/status.json", etag: statusETag) else { return nil }
        let freshStatusETag: String?
        switch signal {
        case .notModified:
            // The page-wide indicator has not moved, so summary.json cannot have changed in
            // a way we care about. This is the branch that runs almost every minute.
            return nil
        case let .body(data, etag):
            // no-log: a decode failure here is already logged by StatusParser itself (it
            // knows the failing key path and expected type; this call site only knows "give
            // up on this poll") — logging again here would just duplicate that line.
            guard (try? StatusParser.indicator(fromStatus: data)) != nil else { return nil }
            freshStatusETag = etag
        }

        // The status ETag is committed only once the summary half of the poll has actually
        // been heard (a 200 that parses, or a 304 saying nothing changed). Committing it
        // above would let one failed summary fetch — right as the page changes for an
        // incident — freeze every later poll into a 304 on the signal, and the incident
        // would go entirely unreported until the page happened to change again.
        guard let summary = await fetch(path: "/api/v2/summary.json", etag: summaryETag) else { return nil }
        switch summary {
        case .notModified:
            statusETag = freshStatusETag
            return nil
        case let .body(data, etag):
            // no-log: see the identical reasoning above — StatusParser already logs its own
            // decode failure with the key path and expected type.
            guard let status = try? StatusParser.serviceStatus(
                fromSummary: data,
                componentNames: componentNames,
                incidentTitleKeywords: incidentTitleKeywords
            ) else { return nil }
            statusETag = freshStatusETag
            summaryETag = etag
            return status
        }
    }

    /// Forgets both ETags, so the next poll asks unconditionally. For callers that just
    /// discarded the last known status (the fixture → live switch): a 304 answers "nothing
    /// changed" about a value the caller no longer holds.
    public func resetETags() {
        statusETag = nil
        summaryETag = nil
    }

    /// Ephemeral: we do our own ETags, so a `URLCache` underneath would only add a second,
    /// invisible caching layer with its own opinions.
    public static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    // MARK: - Transport

    private enum Fetched {
        case notModified
        case body(Data, etag: String?)
    }

    /// A conditional GET. nil means "give up on this poll" — any transport error, any status
    /// other than 200 or 304.
    private func fetch(path: String, etag: String?) async -> Fetched? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        // `path` is one of two hard-coded route literals ("/api/v2/status.json",
        // "/api/v2/summary.json") — never a query parameter, never anything derived from a
        // response — so it is safe to log as-is.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("status poll \(path, privacy: .public) transport failure \(error: error)")
            return nil
        }

        guard let http = response as? HTTPURLResponse else {
            log.error("status poll \(path, privacy: .public) received a non-HTTP response")
            return nil
        }

        log.debug("status poll \(path, privacy: .public) returned status \(http.statusCode)")

        if http.statusCode == 304 {
            log.debug("status poll \(path, privacy: .public) unchanged (etag)")
            return .notModified
        }
        guard http.statusCode == 200 else {
            log.error("status poll \(path, privacy: .public) unexpected status \(http.statusCode)")
            return nil
        }
        return .body(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

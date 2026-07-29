import Foundation
import LassoCrawlReport
import PerfectAdminConsole

/// Tracks the in-progress/last-completed state of the admin console's
/// crawl-report action, so `LassoAdminDelegate.availableActions()` can show
/// live status ("Running now — 340/1,989 pages, started 2m ago" or
/// "Last run: 1,943 clean, 46 failing (finished 11:04 AM)") on the action's
/// chip instead of a static description, and so `executeAction` can reject
/// a second crawl while one is already running.
///
/// `tryBegin()` is the only way `isRunning` flips to `true` — actor
/// serialization makes the check-and-set atomic, so two near-simultaneous
/// `POST /api/actions` calls can't both start a crawl.
///
/// Since the admin-console UI redesign (Phase 12), also retains a bounded
/// history of full runs — including each run's raw `[CrawlPageResult]` — so
/// `currentJob()`/`recentJobRuns()`/`actionReport(for:)` can back the
/// Overview Activity card and the crawl-report-result screen with real data,
/// not just the one-line summary string this tracker used to keep.
actor CrawlRunTracker {
    /// One completed crawl run, retained for `recentJobRuns()`/`actionReport(for:)`.
    struct Run: Sendable {
        let startedAt: Date
        let finishedAt: Date
        let summary: String
        let results: [CrawlPageResult]
        let excludedCount: Int
        let abortedByCircuitBreaker: Bool

        var succeeded: Bool {
            !abortedByCircuitBreaker && results.allSatisfy(\.isClean)
        }
    }

    private(set) var isRunning = false
    private var startedAt: Date?
    private var completed = 0
    private var total = 0
    private var history: [Run] = []
    private let historyCapacity: Int

    init(historyCapacity: Int = 5) {
        self.historyCapacity = historyCapacity
    }

    /// Returns `true` and marks a crawl as started if none is currently
    /// running; returns `false` (leaving state untouched) if one already is.
    @discardableResult
    func tryBegin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        startedAt = Date()
        completed = 0
        total = 0
        return true
    }

    /// Called from `CrawlReport.run`'s `onProgress` callback as pages finish.
    func progress(_ completed: Int, _ total: Int) {
        self.completed = completed
        self.total = total
    }

    func finish(summary: String, results: [CrawlPageResult], excludedCount: Int, abortedByCircuitBreaker: Bool) {
        let started = startedAt ?? Date()
        isRunning = false
        let run = Run(
            startedAt: started, finishedAt: Date(), summary: summary,
            results: results, excludedCount: excludedCount, abortedByCircuitBreaker: abortedByCircuitBreaker
        )
        history.insert(run, at: 0)
        if history.count > historyCapacity {
            history.removeLast(history.count - historyCapacity)
        }
    }

    /// A human-readable status line for the crawl-report action's
    /// description — `fallback` is the static, no-crawl-yet description.
    func statusDescription(fallback: String) -> String {
        if isRunning {
            let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let progressText = total > 0 ? "\(completed)/\(total) pages" : "starting…"
            return "Running now — \(progressText), started \(elapsed)s ago."
        }
        if let lastSummary = history.first?.summary {
            return lastSummary
        }
        return fallback
    }

    /// The most recent run's summary line, or `nil` if none has finished yet —
    /// for `AdminAction.lastResult`, kept separate from `statusDescription`
    /// since that also folds in the live "Running now" text.
    var lastSummary: String? { history.first?.summary }

    /// Maps onto `AdminRunningJob` for `AdminConsoleDelegate.currentJob()`. `nil`
    /// when idle.
    func currentJob(name: String) -> AdminRunningJob? {
        guard isRunning else { return nil }
        return AdminRunningJob(name: name, completed: completed, total: total)
    }

    /// Maps the retained history onto `AdminJobRun` for
    /// `AdminConsoleDelegate.recentJobRuns()`, most recent first.
    func recentJobRuns(name: String) -> [AdminJobRun] {
        history.map {
            AdminJobRun(name: name, startedAt: $0.startedAt, finishedAt: $0.finishedAt, succeeded: $0.succeeded, summary: $0.summary)
        }
    }

    /// Structured drill-down for the most recent run, for
    /// `AdminConsoleDelegate.actionReport(for:)` — `nil` when nothing has run yet.
    func actionReport(name: String) -> AdminActionReport? {
        guard let last = history.first else { return nil }
        let cleanCount = last.results.count { $0.isClean }
        let failing = last.results.filter { $0.isClean == false }
        var stats: [(label: String, value: String, isAlert: Bool)] = [
            (label: "Requested", value: "\(last.results.count)", isAlert: false),
            (label: "Clean", value: "\(cleanCount)", isAlert: false),
            (label: "Failing", value: "\(failing.count)", isAlert: failing.count > 0),
        ]
        if last.excludedCount > 0 {
            stats.append((label: "Excluded", value: "\(last.excludedCount)", isAlert: false))
        }
        let groups = CrawlReport.groupByConstruct(failing).map { construct, pages -> (heading: String, rows: [AdminActionReportRow]) in
            let rows = pages.map { page in
                AdminActionReportRow(
                    label: page.path,
                    status: CrawlReport.failureClass(for: page),
                    detail: page.errorDescription ?? page.errorType,
                    elapsedMS: page.elapsedMS
                )
            }
            return (heading: construct, rows: rows)
        }
        var summary = last.summary
        if last.abortedByCircuitBreaker {
            summary += " Aborted early — circuit breaker tripped on repeated backend failures."
        }
        return AdminActionReport(
            actionName: name,
            generatedAt: last.finishedAt,
            summary: summary,
            stats: stats,
            groups: groups
        )
    }
}

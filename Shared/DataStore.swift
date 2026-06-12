import Foundation

/// Orchestrates a refresh: fetch the rate-limit windows from the API, scan
/// local transcripts for per-model tokens, assemble an `UsageSnapshot`, and
/// cache it for warm starts.
///
/// An actor so the embedded `LocalTokenScanner` (which holds mutable scan
/// state and does synchronous file IO) is accessed serially.
actor DataStore {
    static let shared = DataStore()

    private let scanner = LocalTokenScanner()
    private var lastModelsAll: [ModelUsage] = []
    private var lastModels30d: [ModelUsage] = []
    private var lastModels7d: [ModelUsage] = []
    private var lastScan: Date = .distantPast

    // Cached quota windows so transient failures (429, network) keep showing
    // the last good numbers instead of blanking out.
    private var lastFiveHour: WindowUsage?
    private var lastSevenDay: WindowUsage?
    private var lastQuotaState: QuotaState = .unknown
    private var lastError: String?

    // Quota-endpoint pacing. The endpoint is shared with Claude Code itself and
    // rate-limits aggressively, so we space calls out and back off on 429.
    private var nextQuotaFetch: Date = .distantPast
    private var inPenalty = false
    private var backoff: TimeInterval = DataStore.minBackoff

    /// Normal spacing between successful quota calls.
    private static let quotaInterval: TimeInterval = 120
    private static let minBackoff: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 15 * 60
    /// How often the (heavier) transcript scan runs.
    private let scanInterval: TimeInterval = 5 * 60

    @discardableResult
    func refresh(force: Bool = false) async -> UsageSnapshot {
        let now = Date()

        // Attempt the network call only when due — or on an explicit refresh,
        // unless we're actively serving a 429 penalty.
        if now >= nextQuotaFetch || (force && !inPenalty) {
            await fetchQuota(now: now)
        }

        if force || now.timeIntervalSince(lastScan) >= scanInterval {
            let result = scanner.refresh()
            lastModelsAll = result.all
            lastModels30d = result.d30
            lastModels7d = result.d7
            lastScan = now
        }

        let snapshot = UsageSnapshot(
            fiveHour: lastFiveHour,
            sevenDay: lastSevenDay,
            quotaState: lastQuotaState,
            modelsAll: lastModelsAll,
            models30d: lastModels30d,
            models7d: lastModels7d,
            updatedAt: now,
            error: lastError
        )
        SnapshotCache.save(snapshot)
        return snapshot
    }

    /// Fetches the quota windows and updates the cached state + pacing.
    private func fetchQuota(now: Date) async {
        do {
            let (five, seven) = try await ClaudeUsageAPI.fetchWindows()
            lastFiveHour = five
            lastSevenDay = seven
            lastQuotaState = .available
            lastError = nil
            // Success: resume normal spacing.
            inPenalty = false
            backoff = Self.minBackoff
            nextQuotaFetch = now.addingTimeInterval(Self.quotaInterval)
        } catch let err as ClaudeUsageAPI.APIError {
            lastError = err.errorDescription
            switch err {
            case .noCredentials, .malformedCredentials:
                // Not a subscription: stop polling the endpoint, clear windows.
                lastFiveHour = nil; lastSevenDay = nil
                lastQuotaState = .unavailable
                inPenalty = false
                nextQuotaFetch = now.addingTimeInterval(Self.quotaInterval)
            case .unauthorized:
                lastQuotaState = .needsLogin       // keep last windows visible
                inPenalty = false
                nextQuotaFetch = now.addingTimeInterval(Self.quotaInterval)
            case .rateLimited(let retryAfter):
                lastQuotaState = .rateLimited       // keep last windows visible
                applyBackoff(now: now, retryAfter: retryAfter)
            case .http, .decoding:
                lastQuotaState = .unknown           // keep last windows visible
                applyBackoff(now: now, retryAfter: nil)
            }
        } catch {
            lastError = error.localizedDescription
            lastQuotaState = .unknown
            applyBackoff(now: now, retryAfter: nil)
        }
    }

    /// Exponential backoff (honoring `Retry-After` when present).
    private func applyBackoff(now: Date, retryAfter: TimeInterval?) {
        inPenalty = true
        let delay = retryAfter ?? backoff
        nextQuotaFetch = now.addingTimeInterval(delay)
        backoff = min(backoff * 2, Self.maxBackoff)
    }
}

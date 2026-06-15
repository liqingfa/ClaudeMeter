import Foundation

/// Central configuration. Change `bundlePrefix` to your own reverse-DNS id and
/// keep `project.yml`'s bundle identifier in sync.
enum AppConfig {
    /// Reverse-DNS prefix used for the bundle id.
    static let bundlePrefix = "com.marioo.claudemeter"

    static let snapshotFileName = "usage-snapshot.json"

    /// The app's private support directory, created on first access.
    /// Non-sandboxed, so this is `~/Library/Application Support/ClaudeMeter`.
    static var supportDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Snapshot

/// One rate-limit window (the 5-hour or the 7-day bucket) as reported by the
/// official usage endpoint.
struct WindowUsage: Codable, Equatable {
    /// Utilization as a percentage, 0...100.
    var utilization: Double
    /// Absolute time the window resets.
    var resetsAt: Date

    var fraction: Double { min(max(utilization / 100.0, 0), 1) }
}

/// Per-model token totals, bucketed into the current 5h and 7d windows.
/// Derived from the local Claude Code transcripts (`~/.claude/projects`).
struct ModelUsage: Codable, Equatable, Identifiable {
    var model: String           // e.g. "claude-opus-4-8"
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int

    var id: String { model }

    /// "Active" tokens — everything except cache reads, which are cheap reuse
    /// and otherwise dominate the totals. This is the headline number.
    var activeTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
    var totalTokens: Int { activeTokens + cacheReadTokens }

    /// Friendly label: "claude-opus-4-8" -> "Opus 4.8".
    var displayName: String {
        var s = model
        if let r = s.range(of: "claude-") { s.removeSubrange(r) }
        // drop a trailing date suffix like "-20251001"
        if let r = s.range(of: #"-\d{6,}$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        let parts = s.split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty
            ? family.capitalized
            : "\(family.capitalized) \(version)"
    }
}

struct DailyUsage: Codable, Equatable, Identifiable {
    var day: String
    var models: [ModelUsage]

    var id: String { day }
    var activeTokens: Int { models.reduce(0) { $0 + $1.activeTokens } }
}

/// Availability of the subscription rate-limit quotas (5h / weekly). These only
/// exist for Claude.ai subscriptions (Pro/Max); API-key, Bedrock/Vertex, or
/// logged-out setups have no such windows.
enum QuotaState: String, Codable {
    case available      // windows fetched successfully
    case needsLogin     // OAuth token present but expired/unauthorized
    case unavailable    // no OAuth subscription (API key / Bedrock / not logged in)
    case rateLimited    // endpoint returned 429; backing off, showing last data
    case unknown        // transient failure (network/server); keep calm
}

/// The complete payload shared between processes.
struct UsageSnapshot: Codable, Equatable {
    var fiveHour: WindowUsage?
    var sevenDay: WindowUsage?
    var quotaState: QuotaState
    var modelsAll: [ModelUsage]     // all-time
    var models30d: [ModelUsage]     // last 30 days
    var models7d: [ModelUsage]      // last 7 days
    var modelsToday: [ModelUsage]   // today, up to now
    var models3d: [ModelUsage]      // today + previous 2 days
    var daily3d: [DailyUsage]       // newest day first
    var updatedAt: Date
    /// Optional extra detail for the current quota state (e.g. HTTP error text).
    var error: String?

    enum CodingKeys: String, CodingKey {
        case fiveHour, sevenDay, quotaState, modelsAll, models30d, models7d, modelsToday, models3d, daily3d, updatedAt, error
    }

    init(
        fiveHour: WindowUsage?, sevenDay: WindowUsage?, quotaState: QuotaState,
        modelsAll: [ModelUsage], models30d: [ModelUsage], models7d: [ModelUsage],
        modelsToday: [ModelUsage], models3d: [ModelUsage], daily3d: [DailyUsage], updatedAt: Date, error: String?
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.quotaState = quotaState
        self.modelsAll = modelsAll
        self.models30d = models30d
        self.models7d = models7d
        self.modelsToday = modelsToday
        self.models3d = models3d
        self.daily3d = daily3d
        self.updatedAt = updatedAt
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(WindowUsage.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(WindowUsage.self, forKey: .sevenDay)
        quotaState = try c.decodeIfPresent(QuotaState.self, forKey: .quotaState) ?? .unknown
        modelsAll = try c.decodeIfPresent([ModelUsage].self, forKey: .modelsAll) ?? []
        models30d = try c.decodeIfPresent([ModelUsage].self, forKey: .models30d) ?? []
        models7d = try c.decodeIfPresent([ModelUsage].self, forKey: .models7d) ?? []
        modelsToday = try c.decodeIfPresent([ModelUsage].self, forKey: .modelsToday) ?? []
        models3d = try c.decodeIfPresent([ModelUsage].self, forKey: .models3d) ?? []
        daily3d = try c.decodeIfPresent([DailyUsage].self, forKey: .daily3d) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay, forKey: .sevenDay)
        try c.encode(quotaState, forKey: .quotaState)
        try c.encode(modelsAll, forKey: .modelsAll)
        try c.encode(models30d, forKey: .models30d)
        try c.encode(models7d, forKey: .models7d)
        try c.encode(modelsToday, forKey: .modelsToday)
        try c.encode(models3d, forKey: .models3d)
        try c.encode(daily3d, forKey: .daily3d)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(error, forKey: .error)
    }

    static let empty = UsageSnapshot(
        fiveHour: nil, sevenDay: nil, quotaState: .unknown,
        modelsAll: [], models30d: [], models7d: [], modelsToday: [], models3d: [], daily3d: [],
        updatedAt: .distantPast, error: nil
    )

    /// Placeholder data for widget previews / first launch.
    static let sample: UsageSnapshot = {
        let models = [
            ModelUsage(model: "claude-opus-4-8", inputTokens: 120_000, outputTokens: 90_000,
                       cacheCreationTokens: 30_000, cacheReadTokens: 800_000),
            ModelUsage(model: "claude-sonnet-4-6", inputTokens: 40_000, outputTokens: 25_000,
                       cacheCreationTokens: 8_000, cacheReadTokens: 200_000),
            ModelUsage(model: "claude-haiku-4-5-20251001", inputTokens: 5_000, outputTokens: 3_000,
                       cacheCreationTokens: 1_000, cacheReadTokens: 40_000),
        ]
        let daily = [
            DailyUsage(day: "2026-06-15", models: models),
            DailyUsage(day: "2026-06-14", models: models),
            DailyUsage(day: "2026-06-13", models: models),
        ]
        return UsageSnapshot(
            fiveHour: WindowUsage(utilization: 42, resetsAt: Date().addingTimeInterval(2 * 3600)),
            sevenDay: WindowUsage(utilization: 18, resetsAt: Date().addingTimeInterval(4 * 86_400)),
            quotaState: .available,
            modelsAll: models, models30d: models, models7d: models, modelsToday: models, models3d: models, daily3d: daily,
            updatedAt: Date(), error: nil
        )
    }()
}

// MARK: - On-disk snapshot cache (warm start across launches)

enum SnapshotCache {
    private static var url: URL {
        AppConfig.supportDirectory.appendingPathComponent(AppConfig.snapshotFileName)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ snapshot: UsageSnapshot) {
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("ClaudeMeter: failed to write snapshot: \(error)")
        }
    }

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }
}

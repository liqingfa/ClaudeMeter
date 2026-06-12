import Foundation

/// Incrementally scans Claude Code transcripts (`~/.claude/projects/**/*.jsonl`)
/// and aggregates per-model token usage. Only newly appended bytes are read on
/// each pass.
///
/// Two aggregates are maintained:
///  - `cumulative`: all-time totals per model (never pruned).
///  - `daily`: per-calendar-day totals per model, kept for ~32 days, used for
///    the rolling 7-day / 30-day windows.
final class LocalTokenScanner {

    struct Totals: Codable {
        var input = 0
        var output = 0
        var cacheCreate = 0
        var cacheRead = 0

        mutating func add(_ o: Totals) {
            input += o.input; output += o.output
            cacheCreate += o.cacheCreate; cacheRead += o.cacheRead
        }

        func usage(model: String) -> ModelUsage {
            ModelUsage(model: model, inputTokens: input, outputTokens: output,
                       cacheCreationTokens: cacheCreate, cacheReadTokens: cacheRead)
        }
    }

    private struct State: Codable {
        var offsets: [String: UInt64] = [:]            // file path -> bytes read
        var cumulative: [String: Totals] = [:]          // model -> all-time
        var daily: [String: [String: Totals]] = [:]     // "yyyy-MM-dd" -> model -> totals
    }

    /// Days of per-day history to retain (a little over 30).
    private static let retentionDays = 32

    private let projectsDir: URL
    private let stateURL: URL
    private var state = State()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"          // sorts lexicographically = chronologically
        return f
    }()

    init() {
        projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        stateURL = AppConfig.supportDirectory.appendingPathComponent("scan-state.json")
        loadState()
    }

    // MARK: Public

    /// Reads any new transcript data, prunes old day buckets, persists state,
    /// and returns per-model totals for the all-time / 30-day / 7-day scopes.
    func refresh() -> (all: [ModelUsage], d30: [ModelUsage], d7: [ModelUsage]) {
        scanNewData()
        pruneAndSave()
        return (aggregate(daysBack: nil), aggregate(daysBack: 30), aggregate(daysBack: 7))
    }

    // MARK: Scanning

    private func scanNewData() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            // Skip files we've fully consumed already.
            if state.offsets[url.path] == UInt64(size) { continue }
            readAppended(at: url, fileSize: UInt64(size))
        }
    }

    private func readAppended(at url: URL, fileSize: UInt64) {
        let path = url.path
        var offset = state.offsets[path] ?? 0
        if fileSize < offset { offset = 0 }          // file rotated/truncated
        if fileSize == offset { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.readToEnd(), !chunk.isEmpty else { return }

            // Only consume up to the last complete line.
            guard let lastNewline = chunk.lastIndex(of: 0x0A) else { return }
            let consumable = chunk[chunk.startIndex...lastNewline]

            for lineData in consumable.split(separator: 0x0A) where !lineData.isEmpty {
                record(Data(lineData))
            }
            state.offsets[path] = offset + UInt64(consumable.count)
        } catch {
            // Leave offset untouched; retry next pass.
        }
    }

    private func record(_ data: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["type"] as? String == "assistant",
            let msg = obj["message"] as? [String: Any],
            let model = msg["model"] as? String, !model.isEmpty, model != "<synthetic>",
            let usage = msg["usage"] as? [String: Any]
        else { return }

        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let t = Totals(
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheCreate: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens")
        )
        let date = (obj["timestamp"] as? String).flatMap(ClaudeUsageAPI.parseDate) ?? Date()
        let day = dayFormatter.string(from: date)

        state.cumulative[model, default: Totals()].add(t)
        state.daily[day, default: [:]][model, default: Totals()].add(t)
    }

    // MARK: Aggregation

    /// `daysBack == nil` -> all-time; otherwise the rolling window of the last
    /// `daysBack` calendar days (today included).
    private func aggregate(daysBack: Int?) -> [ModelUsage] {
        var byModel: [String: Totals] = [:]

        if let days = daysBack {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
            let threshold = dayFormatter.string(from: start)
            for (day, models) in state.daily where day >= threshold {
                for (model, totals) in models {
                    byModel[model, default: Totals()].add(totals)
                }
            }
        } else {
            byModel = state.cumulative
        }

        return byModel
            .map { $0.value.usage(model: $0.key) }
            .sorted { $0.activeTokens > $1.activeTokens }
    }

    // MARK: Persistence

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        state = s
    }

    private func pruneAndSave() {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -Self.retentionDays, to: cal.startOfDay(for: Date()))!
        let threshold = dayFormatter.string(from: cutoff)
        state.daily = state.daily.filter { $0.key >= threshold }

        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

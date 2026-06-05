import Foundation
import Combine

// MARK: - Raw JSONL decoding (only fields we need)

private struct RawEntry: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let isSidechain: Bool?
    let message: RawMessage?
}

private struct RawMessage: Decodable {
    let role: String?
    let model: String?
    let usage: RawUsage?
}

private struct RawUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?

    // Matches Claude Desktop's "Total tokens": input + output only.
    // Cache read/write tokens are excluded (they dwarf real usage ~80×).
    var total: Int {
        (input_tokens ?? 0) + (output_tokens ?? 0)
    }
}

// MARK: - Lightweight per-message record

struct MsgRecord {
    let date: Date
    let model: String?      // nil for user messages
    let tokens: Int         // input + output (display metric)
    let input: Int
    let output: Int
    let isAssistant: Bool
    let sessionId: String
}

// MARK: - Time window

enum TimeWindow: String, CaseIterable, Identifiable {
    case all = "All"
    case d30 = "30d"
    case d7 = "7d"
    var id: String { rawValue }

    /// Earliest date included, or nil for all-time.
    func cutoff(now: Date) -> Date? {
        switch self {
        case .all: return nil
        case .d30: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .d7:  return Calendar.current.date(byAdding: .day, value: -7, to: now)
        }
    }
}

// MARK: - Computed stats

struct ModelUsage: Identifiable {
    let model: String
    let messages: Int
    let tokens: Int
    var id: String { model }
}

struct DayActivity: Identifiable {
    let day: Date          // start of day
    let tokens: Int
    let messages: Int
    var id: Date { day }
}

struct Stats {
    var sessions = 0
    var messages = 0
    var totalTokens = 0
    var allTimeTokens = 0
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    var peakHour: Int? = nil
    var favoriteModel: String? = nil
    var models: [ModelUsage] = []
    var heatmap: [DayActivity] = []     // ascending by day

    // Billing (current period, independent of the window toggle)
    var planLabel = "Enterprise"
    var spendUsd = 0.0
    var rawSpendUsd = 0.0          // before calibration factor (list price)
    var spendLimitUsd = 0.0
    var nextReset: Date? = nil
    var calibrated = false
    var spendFraction: Double {
        spendLimitUsd > 0 ? min(1, spendUsd / spendLimitUsd) : 0
    }
}

// MARK: - Engine

@MainActor
final class StatsEngine: ObservableObject {
    @Published var stats = Stats()
    @Published var loading = false
    @Published var lastRefresh: Date? = nil
    @Published var window: TimeWindow = .d30 {
        didSet { recompute() }
    }

    private var allRecords: [MsgRecord] = []
    private var config = AppConfig.load()
    private let projectsDir: URL = {
        FileManager.default.homeDirectoryForUserURL
            .appendingPathComponent(".claude/projects")
    }()

    /// Re-anchor the calibration factor to a fresh real-spend reading.
    /// Captures the current period raw (list price) so factor = real / raw.
    func calibrate(toReal real: Double) {
        guard real > 0, stats.rawSpendUsd > 0 else { return }
        config.calibration = Calibration(realUsd: real, rawUsd: stats.rawSpendUsd)
        config.write()
        recompute()
    }

    func refresh() {
        loading = true
        config = AppConfig.load()   // pick up edits to the config file
        let dir = projectsDir
        Task.detached(priority: .userInitiated) {
            let records = Self.scan(dir: dir)
            await MainActor.run {
                self.allRecords = records
                self.lastRefresh = Date()
                self.loading = false
                self.recompute()
            }
        }
    }

    // MARK: parsing

    nonisolated private static func scan(dir: URL) -> [MsgRecord] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var out: [MsgRecord] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            text.enumerateLines { line, _ in
                guard let d = line.data(using: .utf8),
                      let e = try? decoder.decode(RawEntry.self, from: d),
                      let type = e.type,
                      (type == "user" || type == "assistant"),
                      let tsStr = e.timestamp,
                      let sid = e.sessionId else { return }
                guard let ts = iso.date(from: tsStr) ?? isoNoFrac.date(from: tsStr) else { return }
                let isAssistant = (type == "assistant")
                let u = e.message?.usage
                let input = u?.input_tokens ?? 0
                let output = u?.output_tokens ?? 0
                out.append(MsgRecord(
                    date: ts,
                    model: isAssistant ? e.message?.model : nil,
                    tokens: input + output,
                    input: input,
                    output: output,
                    isAssistant: isAssistant,
                    sessionId: sid
                ))
            }
        }
        return out
    }

    // MARK: aggregation

    private func recompute() {
        let now = Date()
        let cutoff = window.cutoff(now: now)
        let cal = Calendar.current

        let recs = cutoff == nil ? allRecords : allRecords.filter { $0.date >= cutoff! }

        var s = Stats()
        s.messages = recs.count
        s.totalTokens = recs.reduce(0) { $0 + $1.tokens }
        s.allTimeTokens = allRecords.reduce(0) { $0 + $1.tokens }

        // sessions
        s.sessions = Set(recs.map { $0.sessionId }).count

        // active days
        let dayKeys = Set(recs.map { cal.startOfDay(for: $0.date) })
        s.activeDays = dayKeys.count

        // streaks
        let sortedDays = dayKeys.sorted()
        (s.currentStreak, s.longestStreak) = Self.streaks(days: sortedDays, now: now, cal: cal)

        // peak hour (by message count)
        if !recs.isEmpty {
            var hourCounts = [Int: Int]()
            for r in recs { hourCounts[cal.component(.hour, from: r.date), default: 0] += 1 }
            s.peakHour = hourCounts.max { a, b in a.value < b.value }?.key
        }

        // models (assistant only)
        var modelMsgs = [String: Int]()
        var modelToks = [String: Int]()
        for r in recs where r.isAssistant {
            guard let m = r.model else { continue }
            modelMsgs[m, default: 0] += 1
            modelToks[m, default: 0] += r.tokens
        }
        s.models = modelMsgs.keys.map {
            ModelUsage(model: $0, messages: modelMsgs[$0] ?? 0, tokens: modelToks[$0] ?? 0)
        }.sorted { $0.tokens > $1.tokens }
        s.favoriteModel = s.models.max { $0.messages < $1.messages }?.model

        // heatmap
        s.heatmap = Self.buildHeatmap(recs: recs, window: window, now: now, cal: cal)

        // billing — current period, ALWAYS (not affected by window toggle).
        // cost = Σ (input×inPrice + output×outPrice); cache tokens excluded; × calibration factor.
        let (periodStart, nextReset) = Billing.period(
            now: now, resetDay: config.resetDayOfMonth, resetHour: config.resetHour, cal: cal)
        var raw = 0.0
        for r in allRecords where r.isAssistant && r.date >= periodStart {
            let p = config.price(for: r.model)
            raw += (Double(r.input) * p.input + Double(r.output) * p.output) / 1_000_000.0
        }
        s.planLabel = config.planLabel
        s.rawSpendUsd = raw
        s.spendUsd = raw * config.factor
        s.spendLimitUsd = config.spendLimitUsd
        s.nextReset = nextReset
        s.calibrated = config.calibration != nil

        self.stats = s
    }

    nonisolated private static func streaks(days: [Date], now: Date, cal: Calendar) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        var longest = 1, run = 1
        for i in 1..<max(days.count, 1) {
            guard days.count > 1 else { break }
            let prev = days[i - 1], cur = days[i]
            if let diff = cal.dateComponents([.day], from: prev, to: cur).day, diff == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }
        // current streak: count back from today (or yesterday) through consecutive days
        let today = cal.startOfDay(for: now)
        let set = Set(days)
        var current = 0
        var cursor = today
        if !set.contains(today) {
            // allow streak that ended yesterday to still count if today not yet active
            cursor = cal.date(byAdding: .day, value: -1, to: today)!
            if !set.contains(cursor) { return (0, longest) }
        }
        while set.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    nonisolated private static func buildHeatmap(recs: [MsgRecord], window: TimeWindow, now: Date, cal: Calendar) -> [DayActivity] {
        let today = cal.startOfDay(for: now)
        let start: Date
        switch window {
        case .d7:
            start = cal.date(byAdding: .day, value: -6, to: today)!
        case .d30:
            start = cal.date(byAdding: .day, value: -34, to: today)! // 5 weeks
        case .all:
            // span from earliest record to today, capped at 53 weeks
            let earliest = recs.map { cal.startOfDay(for: $0.date) }.min() ?? today
            let cap = cal.date(byAdding: .day, value: -370, to: today)!
            start = max(earliest, cap)
        }

        var toks = [Date: Int]()
        var msgs = [Date: Int]()
        for r in recs {
            let d = cal.startOfDay(for: r.date)
            guard d >= start else { continue }
            toks[d, default: 0] += r.tokens
            msgs[d, default: 0] += 1
        }
        var out: [DayActivity] = []
        var cur = start
        while cur <= today {
            out.append(DayActivity(day: cur, tokens: toks[cur] ?? 0, messages: msgs[cur] ?? 0))
            cur = cal.date(byAdding: .day, value: 1, to: cur)!
        }
        return out
    }
}

private extension FileManager {
    var homeDirectoryForUserURL: URL { homeDirectoryForCurrentUser }
}

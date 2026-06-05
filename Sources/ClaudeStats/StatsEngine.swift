import Foundation
import Combine

// MARK: - Raw JSONL decoding

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
    // Cache read/write tokens excluded (they dwarf real usage ~80×).
    var total: Int { (input_tokens ?? 0) + (output_tokens ?? 0) }
}

// MARK: - Per-message record

struct MsgRecord {
    let date: Date
    let model: String?
    let tokens: Int
    let input: Int
    let output: Int
    let isAssistant: Bool
    let sessionId: String
    let projectDir: String   // encoded dir under ~/.claude/projects/, worktree suffix stripped
}

// MARK: - Time window

enum TimeWindow: String, CaseIterable, Identifiable {
    case all = "All"
    case d30 = "30d"
    case d7 = "7d"
    var id: String { rawValue }

    func cutoff(now: Date) -> Date? {
        switch self {
        case .all: return nil
        case .d30: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .d7:  return Calendar.current.date(byAdding: .day, value: -7, to: now)
        }
    }
}

// MARK: - Computed stats models

struct ModelUsage: Identifiable {
    let model: String
    let messages: Int
    let tokens: Int
    let input: Int
    let output: Int
    let costUsd: Double
    var id: String { model }
}

struct ProjectUsage: Identifiable {
    let name: String      // humanized display name
    let dirKey: String    // raw encoded dir (unique key)
    let sessions: Int
    let tokens: Int
    let costUsd: Double
    var id: String { dirKey }
}

struct DayActivity: Identifiable {
    let day: Date
    let tokens: Int
    let messages: Int
    let costUsd: Double
    var id: Date { day }
}

struct Stats {
    var sessions = 0
    var messages = 0
    var totalTokens = 0
    var tokensToday = 0
    var avgTokensPerSession = 0
    var avgTokensPerDay = 0
    var outputRatio = 0.0       // output / (input + output) for assistant messages
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    var peakHour: Int? = nil
    var favoriteModel: String? = nil
    var models: [ModelUsage] = []
    var projects: [ProjectUsage] = []
    var heatmap: [DayActivity] = []

    var planLabel = "Enterprise"
    var spendUsd = 0.0
    var rawSpendUsd = 0.0
    var spendLimitUsd = 0.0
    var nextReset: Date? = nil
    var calibrated = false
    var projectedSpendUsd: Double? = nil
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


    func calibrate(toReal real: Double) {
        guard real > 0, stats.rawSpendUsd > 0 else { return }
        config.calibration = Calibration(realUsd: real, rawUsd: stats.rawSpendUsd)
        config.write()
        recompute()
    }

    func refresh() {
        loading = true
        config = AppConfig.load()
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

    // MARK: - Parsing

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
            // project dir = immediate child of ~/.claude/projects/; strip worktree suffix so
            // worktrees are grouped under their parent project
            var projectDir = url.deletingLastPathComponent().lastPathComponent
            if let r = projectDir.range(of: "--claude-worktrees") {
                projectDir = String(projectDir[..<r.lowerBound])
            }

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
                    sessionId: sid,
                    projectDir: projectDir
                ))
            }
        }
        return out
    }

    // MARK: - Project display name

    nonisolated private static func displayName(forDir dir: String) -> String {
        var s = dir
        // strip worktree suffix (already stripped in scan, but defensive)
        if let r = s.range(of: "--claude-worktrees") { s = String(s[..<r.lowerBound]) }
        // strip leading -
        if s.hasPrefix("-") { s = String(s.dropFirst()) }
        // strip encoded home prefix (e.g. "Users-joan-gil-")
        if s.hasPrefix(_homePrefix) { s = String(s.dropFirst(_homePrefix.count)) }
        if s.isEmpty { return "Home" }
        // replace remaining - with / to recover approximate path structure
        return s.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Aggregation

    private func recompute() {
        let now = Date()
        let cutoff = window.cutoff(now: now)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        let recs = cutoff == nil ? allRecords : allRecords.filter { $0.date >= cutoff! }

        var s = Stats()
        s.messages = recs.count
        s.totalTokens = recs.reduce(0) { $0 + $1.tokens }

        // tokens today (always from current day, not window-affected in practice)
        s.tokensToday = recs.filter { cal.startOfDay(for: $0.date) == today }
                            .reduce(0) { $0 + $1.tokens }

        // sessions
        s.sessions = Set(recs.map { $0.sessionId }).count

        // active days
        let dayKeys = Set(recs.map { cal.startOfDay(for: $0.date) })
        s.activeDays = dayKeys.count

        // averages
        s.avgTokensPerSession = s.sessions > 0 ? s.totalTokens / s.sessions : 0
        s.avgTokensPerDay = s.activeDays > 0 ? s.totalTokens / s.activeDays : 0

        // streaks
        let sortedDays = dayKeys.sorted()
        (s.currentStreak, s.longestStreak) = Self.streaks(days: sortedDays, now: now, cal: cal)

        // peak hour
        if !recs.isEmpty {
            var hourCounts = [Int: Int]()
            for r in recs { hourCounts[cal.component(.hour, from: r.date), default: 0] += 1 }
            s.peakHour = hourCounts.max { a, b in a.value < b.value }?.key
        }

        // output ratio: what fraction of tokens are Claude's actual responses vs context
        let assistantRecs = recs.filter { $0.isAssistant }
        let totalOut = assistantRecs.reduce(0) { $0 + $1.output }
        let totalAssistant = assistantRecs.reduce(0) { $0 + $1.tokens }
        s.outputRatio = totalAssistant > 0 ? Double(totalOut) / Double(totalAssistant) : 0

        // models (assistant only)
        var modelMsgs  = [String: Int]()
        var modelToks  = [String: Int]()
        var modelInput = [String: Int]()
        var modelOut   = [String: Int]()
        var dayCost    = [Date: Double]()
        for r in recs where r.isAssistant {
            guard let m = r.model else { continue }
            modelMsgs[m, default: 0]  += 1
            modelToks[m, default: 0]  += r.tokens
            modelInput[m, default: 0] += r.input
            modelOut[m, default: 0]   += r.output
            let p = config.price(for: m)
            dayCost[cal.startOfDay(for: r.date), default: 0] +=
                (Double(r.input) * p.input + Double(r.output) * p.output) / 1_000_000 * config.factor
        }
        s.models = modelMsgs.keys.map { key in
            let inp  = modelInput[key] ?? 0
            let out  = modelOut[key] ?? 0
            let p    = config.price(for: key)
            let cost = (Double(inp) * p.input + Double(out) * p.output) / 1_000_000 * config.factor
            return ModelUsage(model: key, messages: modelMsgs[key] ?? 0,
                              tokens: modelToks[key] ?? 0, input: inp, output: out, costUsd: cost)
        }.sorted { $0.tokens > $1.tokens }
        s.favoriteModel = s.models.max { $0.messages < $1.messages }?.model

        // projects
        var projToks     = [String: Int]()
        var projSessions = [String: Set<String>]()
        var projCost     = [String: Double]()
        for r in recs {
            let k = r.projectDir
            projSessions[k, default: Set()].insert(r.sessionId)
            if r.isAssistant {
                projToks[k, default: 0] += r.tokens
                let p = config.price(for: r.model)
                projCost[k, default: 0] += (Double(r.input) * p.input + Double(r.output) * p.output) / 1_000_000
            }
        }
        s.projects = projToks.keys.map { k in
            ProjectUsage(
                name: Self.displayName(forDir: k),
                dirKey: k,
                sessions: projSessions[k]?.count ?? 0,
                tokens: projToks[k] ?? 0,
                costUsd: (projCost[k] ?? 0) * config.factor
            )
        }.sorted { $0.tokens > $1.tokens }

        // heatmap
        s.heatmap = Self.buildHeatmap(recs: recs, window: window, now: now, cal: cal, dailyCost: dayCost)

        // billing — always from allRecords (not window-scoped)
        let (periodStart, nextReset) = Billing.period(
            now: now, resetDay: config.resetDayOfMonth, resetHour: config.resetHour, cal: cal)
        var raw = 0.0
        for r in allRecords where r.isAssistant && r.date >= periodStart {
            let p = config.price(for: r.model)
            raw += (Double(r.input) * p.input + Double(r.output) * p.output) / 1_000_000.0
        }
        s.planLabel    = config.planLabel
        s.rawSpendUsd  = raw
        s.spendUsd     = raw * config.factor
        s.spendLimitUsd = config.spendLimitUsd
        s.nextReset    = nextReset
        s.calibrated   = config.calibration != nil

        // spend projection: extrapolate daily rate to end of billing period
        if s.spendUsd > 0 {
            let daysPassed   = max(1, cal.dateComponents([.day], from: periodStart, to: now).day ?? 1)
            let daysInPeriod = max(1, cal.dateComponents([.day], from: periodStart, to: nextReset).day ?? 1)
            s.projectedSpendUsd = (s.spendUsd / Double(daysPassed)) * Double(daysInPeriod)
        }

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
        let today = cal.startOfDay(for: now)
        let set = Set(days)
        var current = 0
        var cursor = today
        if !set.contains(today) {
            cursor = cal.date(byAdding: .day, value: -1, to: today)!
            if !set.contains(cursor) { return (0, longest) }
        }
        while set.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    nonisolated private static func buildHeatmap(recs: [MsgRecord], window: TimeWindow, now: Date, cal: Calendar, dailyCost: [Date: Double]) -> [DayActivity] {
        let today = cal.startOfDay(for: now)
        let start: Date
        switch window {
        case .d7:  start = cal.date(byAdding: .day, value: -6, to: today)!
        case .d30: start = cal.date(byAdding: .day, value: -34, to: today)!
        case .all:
            let earliest = recs.map { cal.startOfDay(for: $0.date) }.min() ?? today
            let cap = cal.date(byAdding: .day, value: -370, to: today)!
            start = max(earliest, cap)
        }
        var toks = [Date: Int](); var msgs = [Date: Int]()
        for r in recs {
            let d = cal.startOfDay(for: r.date)
            guard d >= start else { continue }
            toks[d, default: 0] += r.tokens
            msgs[d, default: 0] += 1
        }
        var out: [DayActivity] = []
        var cur = start
        while cur <= today {
            out.append(DayActivity(day: cur, tokens: toks[cur] ?? 0, messages: msgs[cur] ?? 0, costUsd: dailyCost[cur] ?? 0))
            cur = cal.date(byAdding: .day, value: 1, to: cur)!
        }
        return out
    }
}

// File-level constant: avoids @MainActor isolation issues when accessed from nonisolated funcs.
private let _homePrefix: String = {
    let path = FileManager.default.homeDirectoryForCurrentUser.path
    let encoded = path
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
    return stripped + "-"
}()

private extension FileManager {
    var homeDirectoryForUserURL: URL { homeDirectoryForCurrentUser }
}

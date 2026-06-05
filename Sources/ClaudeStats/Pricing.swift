import Foundation

// MARK: - Pricing (USD per 1M tokens, input + output only; cache excluded)

struct ModelPrice: Codable {
    var input: Double
    var output: Double
}

// MARK: - User config (~/.claude/claude-stats-config.json)

struct Calibration: Codable {
    var realUsd: Double
    var rawUsd: Double
    var factor: Double { rawUsd > 0 ? realUsd / rawUsd : 1.0 }
}

struct AppConfig {
    var planLabel = "Enterprise"
    var spendLimitUsd = 1500.0
    var resetDayOfMonth = 1
    var resetHour = 2
    var prices: [String: ModelPrice] = [
        "opus":   ModelPrice(input: 15, output: 75),
        "sonnet": ModelPrice(input: 3,  output: 15),
        "haiku":  ModelPrice(input: 1,  output: 5),
    ]
    var calibration: Calibration? = nil

    /// Price for a model string (substring match), default to Sonnet-class.
    func price(for model: String?) -> ModelPrice {
        let m = (model ?? "").lowercased()
        for (key, p) in prices where m.contains(key) { return p }
        return prices["sonnet"] ?? ModelPrice(input: 3, output: 15)
    }

    var factor: Double { calibration?.factor ?? 1.0 }

    static func load() -> AppConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url) {
            return decode(data)
        }
        let def = AppConfig()
        def.write()
        return def
    }

    func write() {
        try? JSONEncoder.pretty.encode(self.asDTO).write(to: Self.configURL)
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/claude-stats-config.json")
    }
}

// MARK: - Codable bridge with per-field defaults

private struct ConfigDTO: Codable {
    var planLabel: String?
    var spendLimitUsd: Double?
    var resetDayOfMonth: Int?
    var resetHour: Int?
    var prices: [String: ModelPrice]?
    var calibration: Calibration?
}

private extension AppConfig {
    var asDTO: ConfigDTO {
        ConfigDTO(planLabel: planLabel, spendLimitUsd: spendLimitUsd,
                  resetDayOfMonth: resetDayOfMonth, resetHour: resetHour,
                  prices: prices, calibration: calibration)
    }

    static func decode(_ data: Data) -> AppConfig {
        var cfg = AppConfig()
        guard let dto = try? JSONDecoder().decode(ConfigDTO.self, from: data) else { return cfg }
        if let v = dto.planLabel { cfg.planLabel = v }
        if let v = dto.spendLimitUsd { cfg.spendLimitUsd = v }
        if let v = dto.resetDayOfMonth { cfg.resetDayOfMonth = v }
        if let v = dto.resetHour { cfg.resetHour = v }
        if let v = dto.prices, !v.isEmpty { cfg.prices = v }
        cfg.calibration = dto.calibration
        return cfg
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}

// MARK: - Billing period math

enum Billing {
    /// Start of the current billing period (most recent resetDay) and the next reset date.
    static func period(now: Date, resetDay: Int, resetHour: Int, cal: Calendar) -> (start: Date, nextReset: Date) {
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.day = resetDay
        comps.hour = resetHour
        comps.minute = 0
        let thisMonthReset = cal.date(from: comps) ?? now
        let start: Date = thisMonthReset <= now
            ? thisMonthReset
            : (cal.date(byAdding: .month, value: -1, to: thisMonthReset) ?? thisMonthReset)
        let next = cal.date(byAdding: .month, value: 1, to: start) ?? now
        return (start, next)
    }
}

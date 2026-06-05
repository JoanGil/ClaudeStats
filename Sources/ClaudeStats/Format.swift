import Foundation

enum Fmt {
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000...:
            return trim(d / 1_000_000) + "M"
        case 1_000...:
            return trim(d / 1_000) + "K"
        default:
            return "\(n)"
        }
    }

    private static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func hour(_ h: Int) -> String {
        let period = h < 12 ? "AM" : "PM"
        var hr = h % 12
        if hr == 0 { hr = 12 }
        return "\(hr) \(period)"
    }

    /// Pretty model label, e.g. claude-opus-4-8 -> "Opus 4.8".
    static func modelLabel(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // strip trailing date suffix like -20251001
        let parts = s.split(separator: "-")
        var kept: [String] = []
        for p in parts {
            if p.count == 8, Int(p) != nil { continue }   // date stamp
            kept.append(String(p))
        }
        guard let family = kept.first else { return raw }
        let nums = kept.dropFirst().filter { Int($0) != nil }
        let ver = nums.joined(separator: ".")
        let fam = family.prefix(1).uppercased() + family.dropFirst()
        return ver.isEmpty ? fam : "\(fam) \(ver)"
    }
}

// MARK: - Fun comparison

struct Book { let name: String; let tokens: Int }

enum Comparison {
    // Rough token counts (~1.3 tokens/word).
    static let books: [Book] = [
        Book(name: "Pride and Prejudice", tokens: 155_000),
        Book(name: "The Great Gatsby", tokens: 64_000),
        Book(name: "The Hobbit", tokens: 124_000),
        Book(name: "Harry Potter and the Sorcerer's Stone", tokens: 99_000),
        Book(name: "Moby-Dick", tokens: 275_000),
        Book(name: "War and Peace", tokens: 750_000),
        Book(name: "The Lord of the Rings", tokens: 600_000),
    ]

    static func line(totalTokens: Int) -> String? {
        guard totalTokens > 0 else { return nil }
        let base = books[0]   // Pride and Prejudice, matching the desktop app
        let mult = Double(totalTokens) / Double(base.tokens)
        if mult >= 1 {
            let m = mult >= 10 ? String(format: "%.0f", mult) : String(format: "%.0f", mult.rounded())
            return "You've used ~\(m)× more tokens than \(base.name)."
        } else {
            let pct = Int((mult * 100).rounded())
            return "You've used ~\(pct)% of the tokens in \(base.name)."
        }
    }
}

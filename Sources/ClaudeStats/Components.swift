import SwiftUI

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// GitHub-style activity grid. Columns = weeks, rows = weekdays.
struct Heatmap: View {
    let days: [DayActivity]
    private let rows = 7
    private let gap: CGFloat = 4
    private let maxCell: CGFloat = 16
    private let minCell: CGFloat = 6

    private var maxTokens: Int { max(days.map { $0.tokens }.max() ?? 0, 1) }

    private var columns: [[DayActivity?]] {
        let cal = Calendar.current
        guard let first = days.first else { return [] }
        let lead = (cal.component(.weekday, from: first.day) - 1)
        var padded: [DayActivity?] = Array(repeating: nil, count: lead)
        padded.append(contentsOf: days.map { Optional($0) })
        while padded.count % rows != 0 { padded.append(nil) }
        return stride(from: 0, to: padded.count, by: rows).map {
            Array(padded[$0..<min($0 + rows, padded.count)])
        }
    }

    private func color(_ t: Int) -> Color {
        guard t > 0 else { return Color.primary.opacity(0.08) }
        let ratio = Double(t) / Double(maxTokens)
        let intensity = 0.25 + 0.75 * min(1, sqrt(ratio))
        return Color.accentColor.opacity(intensity)
    }

    var body: some View {
        let cols = columns
        return GeometryReader { geo in
            let n = max(cols.count, 1)
            let fit = (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let cell = min(maxCell, max(minCell, fit))
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    VStack(spacing: gap) {
                        ForEach(0..<rows, id: \.self) { r in
                            let day = r < col.count ? col[r] : nil
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color(day?.tokens ?? 0))
                                .frame(width: cell, height: cell)
                                .help(tooltip(day))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: maxCell * CGFloat(rows) + gap * CGFloat(rows - 1))
    }

    private func tooltip(_ d: DayActivity?) -> String {
        guard let d, d.messages > 0 else { return "" }
        let df = DateFormatter(); df.dateStyle = .medium
        return "\(df.string(from: d.day)): \(d.messages) msgs, \(Fmt.compact(d.tokens)) tokens"
    }
}

struct UsageLimitsPanel: View {
    let stats: Stats

    private func usd(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    private var resetText: String {
        guard let r = stats.nextReset else { return "Spend limit" }
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d, h:mm a 'GMT'ZZZZZ"
        return "Spend limit · Resets \(df.string(from: r))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Your usage limits")
                    .font(.system(size: 16, weight: .bold))
                Text(stats.planLabel)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(usd(stats.spendUsd)) of \(usd(stats.spendLimitUsd)) spent")
                        .font(.system(size: 14, weight: .medium))
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(6, geo.size.width * stats.spendFraction))
                    }
                }
                .frame(width: 160, height: 8)
                Text("\(Int((stats.spendFraction * 100).rounded()))% used")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text(stats.calibrated
                 ? "Calibrated estimate from local tokens · ~/.claude/claude-stats-config.json"
                 : "Estimated from local tokens (uncalibrated) · ~/.claude/claude-stats-config.json")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Compact per-model token share beside the heatmap on Overview.
struct CompactModels: View {
    let models: [ModelUsage]

    private var total: Int { max(models.reduce(0) { $0 + $1.tokens }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if models.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(models.prefix(5).enumerated()), id: \.element.id) { idx, m in
                    let pct = Int((Double(m.tokens) / Double(total) * 100).rounded())
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.accentColor.opacity(1.0 - Double(idx) * 0.16))
                            .frame(width: 7, height: 7)
                        Text(Fmt.modelLabel(m.model))
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(pct)%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(width: 150, alignment: .leading)
    }
}

/// Model row with gradient split bar (bright = input/context, dim = output/generation).
struct ModelBar: View {
    let usage: ModelUsage
    let maxTokens: Int

    private var inputFrac: Double {
        let total = usage.input + usage.output
        return total > 0 ? Double(usage.input) / Double(total) : 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Fmt.modelLabel(usage.model))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(String(format: "$%.2f", usage.costUsd))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            // bar width = proportion of max; colour split = input (bright) / output (dim)
            GeometryReader { geo in
                let barW = max(6, geo.size.width * CGFloat(usage.tokens) / CGFloat(maxTokens))
                let gradient = LinearGradient(
                    stops: [
                        .init(color: .accentColor,                  location: 0),
                        .init(color: .accentColor,                  location: inputFrac),
                        .init(color: .accentColor.opacity(0.4),     location: inputFrac),
                        .init(color: .accentColor.opacity(0.4),     location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4).fill(gradient).frame(width: barW)
                }
            }
            .frame(height: 8)
            HStack(spacing: 0) {
                Text("↑ \(Fmt.compact(usage.input)) in")
                    .foregroundStyle(.secondary)
                Text("  ·  ").foregroundStyle(.tertiary)
                Text("↓ \(Fmt.compact(usage.output)) out")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.grouped(usage.messages)) msgs")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
        }
    }
}

/// Project row with token bar and cost.
struct ProjectRow: View {
    let project: ProjectUsage
    let maxTokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "$%.2f", project.costUsd))
                    .font(.system(size: 12, weight: .semibold))
            }
            GeometryReader { geo in
                let w = maxTokens > 0 ? CGFloat(project.tokens) / CGFloat(maxTokens) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(6, geo.size.width * w))
                }
            }
            .frame(height: 8)
            HStack(spacing: 0) {
                Text("\(Fmt.compact(project.tokens)) tokens")
                    .foregroundStyle(.secondary)
                Text("  ·  ").foregroundStyle(.tertiary)
                Text("\(project.sessions) \(project.sessions == 1 ? "session" : "sessions")")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
        }
    }
}

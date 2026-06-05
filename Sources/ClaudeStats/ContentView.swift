import SwiftUI

enum Tab { case overview, models, projects }

@MainActor
final class UIState: ObservableObject {
    @Published var tab: Tab = .overview
}

struct ContentView: View {
    @ObservedObject var engine: StatsEngine
    @ObservedObject var ui: UIState
    @State private var calibrating = false
    @State private var realText = ""

    private var tab: Tab { ui.tab }

    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageLimitsPanel(stats: engine.stats)
            Divider()
            header
            Group {
                if engine.loading && engine.lastRefresh == nil {
                    ProgressView("Reading sessions…")
                        .frame(maxWidth: .infinity)
                } else if tab == .overview {
                    overview
                } else if tab == .models {
                    models
                } else {
                    projects
                }
            }
            .frame(height: 390, alignment: .top)
            footer
        }
        .padding(16)
        .frame(width: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 4) {
                tabButton("Overview",  .overview)
                tabButton("Models",    .models)
                tabButton("Projects",  .projects)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(Array(TimeWindow.allCases.enumerated()), id: \.element.id) { idx, w in
                    Button { engine.window = w } label: {
                        Text("\(idx + 1)").font(.system(size: 8)).baselineOffset(5)
                            .foregroundColor(.secondary)
                        + Text(w.rawValue)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(engine.window == w ? Color.primary.opacity(0.12) : .clear)
                    )
                    .font(.system(size: 12, weight: engine.window == w ? .semibold : .regular))
                }
            }
        }
    }

    private func tabButton(_ title: String, _ t: Tab) -> some View {
        let first = Text(String(title.prefix(1))).underline()
        let rest  = Text(String(title.dropFirst()))
        return Button(action: { ui.tab = t }) { first + rest }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tab == t ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .font(.system(size: 14, weight: tab == t ? .semibold : .regular))
    }

    // MARK: - Overview

    private var overview: some View {
        let s = engine.stats
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: cols, spacing: 10) {
                // row 1: activity
                StatTile(title: "Sessions",     value: Fmt.grouped(s.sessions))
                StatTile(title: "Messages",     value: Fmt.grouped(s.messages))
                StatTile(title: "Total tokens", value: Fmt.compact(s.totalTokens))
                StatTile(title: "Active days",  value: "\(s.activeDays)")
                // row 2: depth
                StatTile(title: "Tokens today", value: Fmt.compact(s.tokensToday))
                StatTile(title: "Avg/session",  value: Fmt.compact(s.avgTokensPerSession))
                StatTile(title: "Avg/day",      value: Fmt.compact(s.avgTokensPerDay))
                StatTile(title: "Output %",     value: "\(Int((s.outputRatio * 100).rounded()))%")
                // row 3: streaks + model
                StatTile(title: "Current streak",  value: "\(s.currentStreak)d")
                StatTile(title: "Longest streak",  value: "\(s.longestStreak)d")
                StatTile(title: "Peak hour",       value: s.peakHour.map(Fmt.hour) ?? "—")
                StatTile(title: "Favorite model",  value: s.favoriteModel.map(Fmt.modelLabel) ?? "—")
            }
            HStack(alignment: .top, spacing: 14) {
                Heatmap(days: s.heatmap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CompactModels(models: s.models)
            }
            .padding(.top, 4)
            if let line = Comparison.line(totalTokens: s.totalTokens) {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Models

    private var models: some View {
        let s = engine.stats
        let maxT = s.models.map { $0.tokens }.max() ?? 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if s.models.isEmpty {
                    Text("No model usage in this window.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(s.models) { m in
                        ModelBar(usage: m, maxTokens: maxT)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 220)
    }

    // MARK: - Projects

    private var projects: some View {
        let s = engine.stats
        let maxT = s.projects.first?.tokens ?? 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if s.projects.isEmpty {
                    Text("No project data in this window.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(s.projects) { p in
                        ProjectRow(project: p, maxTokens: maxT)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 220)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let r = engine.lastRefresh {
                Text("Updated \(r.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            if calibrating {
                Text("Real $").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("", text: $realText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .font(.system(size: 11))
                    .onSubmit(applyCalibration)
                Button("Set", action: applyCalibration)
                    .controlSize(.small)
                Button { calibrating = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Cancel")
            } else {
                Button {
                    realText = String(format: "%.2f", engine.stats.spendUsd)
                    calibrating = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }.buttonStyle(.plain).help("Calibrate to real spend")
            }
            Button { engine.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.plain).help("Refresh")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }.buttonStyle(.plain).help("Quit")
        }
    }

    private func applyCalibration() {
        if let v = Double(realText.replacingOccurrences(of: ",", with: ".")) {
            engine.calibrate(toReal: v)
        }
        calibrating = false
    }
}

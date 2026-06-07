import SwiftUI
import BabyLogCore

/// "Prep for visit" screen — a shareable digest of what's been logged since the
/// last appointment. Presented as a sheet from the Appointments tab.
struct VisitSummaryView: View {

    @State var viewModel: VisitSummaryViewModel
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Visit summary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", action: onDismiss)
                            .accessibilityIdentifier("visitSummaryDoneButton")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if viewModel.state == .loaded {
                            ShareLink(item: viewModel.shareText) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share visit summary")
                            .accessibilityIdentifier("visitSummaryShareButton")
                        }
                    }
                }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Gathering this period…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't build the summary", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await viewModel.load() } }
            }
        case .loaded:
            if let summary = viewModel.summary {
                loaded(summary)
            }
        }
    }

    private func loaded(_ summary: VisitSummary) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.childName).font(.title3.weight(.semibold))
                    Text(periodLine(summary))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let next = summary.nextAppointment {
                        Label("\(next.title) · \(next.date.formatted(date: .abbreviated, time: .omitted))",
                              systemImage: "calendar")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            section("Feeds", systemImage: "waterbottle.fill", rows: feedRows(summary.feeds))
            section("Diapers", systemImage: "drop.fill", rows: diaperRows(summary.diapers))
            section("Growth", systemImage: "chart.line.uptrend.xyaxis", rows: growthRows(summary.growth))
            if summary.pumping.count > 0 {
                section("Pumping", systemImage: "drop.circle.fill",
                        rows: ["\(summary.pumping.count) sessions · \(summary.pumping.totalMl) ml total"])
            }
            section("Milestones", systemImage: "star.fill", rows: milestoneRows(summary.milestones))

            Section {
                Text("Figures reflect what was recorded, not medical advice.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Rows

    private func section(_ title: String, systemImage: String, rows: [String]) -> some View {
        Section {
            ForEach(rows, id: \.self) { Text($0).font(.subheadline) }
        } header: {
            Label(title, systemImage: systemImage)
        }
    }

    private func periodLine(_ s: VisitSummary) -> String {
        let from = s.since.formatted(date: .abbreviated, time: .omitted)
        let to = s.until.formatted(date: .abbreviated, time: .omitted)
        let age = s.ageLabel.isEmpty ? "" : "Age \(s.ageLabel) · "
        return "\(age)\(from) – \(to) (\(s.dayCount) day\(s.dayCount == 1 ? "" : "s"))"
    }

    private func feedRows(_ f: VisitSummary.FeedsSection) -> [String] {
        guard f.count > 0 else { return ["None logged this period"] }
        var rows = ["\(f.count) feeds · avg \(f.avgMlPerDay) ml/day across \(oneDecimal(f.feedsPerDay)) feeds/day"]
        var second = "\(f.nightFeeds) night feeds"
        if let iv = f.avgIntervalSeconds { second += " · avg \(duration(iv)) between feeds" }
        rows.append(second)
        return rows
    }

    private func diaperRows(_ d: VisitSummary.DiapersSection) -> [String] {
        guard d.count > 0 else { return ["None logged this period"] }
        let breakdown = d.byType.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
        return ["\(d.count) changes · avg \(oneDecimal(d.avgPerDay))/day (\(breakdown))"]
    }

    private func growthRows(_ g: VisitSummary.GrowthSection) -> [String] {
        if g.latestWeightGrams == nil && g.latestHeightCm == nil && g.latestHeadCm == nil {
            return ["None logged"]
        }
        var rows: [String] = []
        if let w = g.latestWeightGrams {
            var s = "Weight \(String(format: "%.2f kg", Double(w) / 1000))"
            if let d = g.weightDeltaGrams { s += " (\(d >= 0 ? "+" : "")\(d) g this period)" }
            rows.append(s)
        }
        var measures: [String] = []
        if let h = g.latestHeightCm { measures.append("Height \(oneDecimal(h)) cm") }
        if let hc = g.latestHeadCm { measures.append("Head \(oneDecimal(hc)) cm") }
        if !measures.isEmpty { rows.append(measures.joined(separator: " · ")) }
        return rows
    }

    private func milestoneRows(_ m: [VisitSummary.MilestoneRef]) -> [String] {
        guard !m.isEmpty else { return ["None this period"] }
        return m.map { "\($0.title) — \($0.date.formatted(date: .abbreviated, time: .omitted))" }
    }

    private func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}

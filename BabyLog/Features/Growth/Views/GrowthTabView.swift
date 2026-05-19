import SwiftUI
import BabyLogCore

struct GrowthTabView: View {

    @State var viewModel: GrowthMeasurementViewModel
    var onSync: (() async -> Void)?

    var body: some View {
        LoggingTabScaffold(
            title: "Growth",
            accent: Theme.growth,
            addButtonLabel: "Add measurement",
            addButtonHint: "Opens form to log a new measurement",
            addButtonIdentifier: "growthAddButton",
            formTitle: "New measurement",
            formDoneIdentifier: "growthFormDoneButton",
            onSync: onSync,
            onRefresh: { await viewModel.refreshEntries() },
            summary: { summaryCard },
            primaryChart: { GrowthChartView(entries: viewModel.entries) },
            history: {
                if viewModel.entries.isEmpty {
                    WarmEmptyState(
                        title: "No Measurements Yet",
                        message: "Tap + to log a weight, height, or head circumference.",
                        systemImage: "ruler.fill",
                        tint: Theme.growth
                    )
                    .accessibilityIdentifier("growthEmptyState")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section("History") {
                        ForEach(viewModel.entries, id: \.id.value) { entry in
                            GrowthMeasurementRow(entry: entry)
                        }
                    }
                    .accessibilityIdentifier("growthHistoryList")
                }
            },
            form: {
                GrowthMeasurementFormView(viewModel: viewModel)
            }
        )
    }

    @ViewBuilder
    private var summaryCard: some View {
        let summary = viewModel.summary
        if summary.latestWeightGrams != nil
            || summary.latestHeightCm != nil
            || summary.latestHeadCm != nil {
            DailyTotalCard(
                title: "Growth",
                primary: primaryLine(summary),
                secondary: secondaryLine(summary),
                accent: Theme.growth,
                accentIcon: "ruler.fill"
            )
            .accessibilityIdentifier("growthSummary")
        }
    }

    private func primaryLine(_ summary: GrowthAnalytics.Summary) -> String {
        guard let grams = summary.latestWeightGrams else {
            return "No measurements yet"
        }
        if grams >= 1_000 {
            return String(format: "%.2f kg", Double(grams) / 1_000.0)
        }
        return "\(grams) g"
    }

    private func secondaryLine(_ summary: GrowthAnalytics.Summary) -> String? {
        if let delta = summary.weightDeltaGramsLastWeek {
            return Self.formatDelta(delta)
        }
        var parts: [String] = []
        if let h = summary.latestHeightCm {
            parts.append(String(format: "%.1f cm", h))
        }
        if let hc = summary.latestHeadCm {
            parts.append(String(format: "head %.1f cm", hc))
        }
        if parts.isEmpty {
            return summary.latestWeightGrams == nil ? nil : "No trend yet"
        }
        return parts.joined(separator: " · ")
    }

    static func formatDelta(_ deltaGrams: Int) -> String {
        let sign = deltaGrams >= 0 ? "+" : "-"
        let magnitude = abs(deltaGrams)
        if magnitude < 1_000 {
            return "\(sign)\(magnitude) g this week"
        }
        return String(format: "%@%.1f kg this week", sign, Double(magnitude) / 1_000.0)
    }
}

private struct GrowthMeasurementRow: View {
    let entry: GrowthMeasurement

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.date, style: .date)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(RelativeTime.shortLabel(for: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let w = entry.weightGrams {
                    Badge(
                        systemImage: "scalemass.fill",
                        text: String(format: "%.2f kg", Double(w) / 1000.0),
                        tint: .orange
                    )
                }
                if let h = entry.heightCm {
                    Badge(
                        systemImage: "ruler.fill",
                        text: String(format: "%.1f cm", h),
                        tint: .green
                    )
                }
                if let hc = entry.headCircumferenceCm {
                    Badge(
                        systemImage: "circle.dashed",
                        text: String(format: "%.1f cm", hc),
                        tint: .teal
                    )
                }
            }
            if let notes = entry.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    GrowthTabView(viewModel: GrowthMeasurementViewModel(
        repository: InMemoryGrowthMeasurementRepository(),
        clock: SystemClock()
    ))
}

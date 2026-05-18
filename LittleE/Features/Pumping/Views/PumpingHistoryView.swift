import SwiftUI
import Charts
import LittleECore

/// Push-nav screen reached from the Pumping tab's "View history" row.
///
/// Layout:
///   - 30-day volume trend chart (Swift Charts BarMark, pink)
///   - One Section per day with a header showing total volume + minutes
///   - Each row is a reused `PumpingHistoryRow` (time / side / duration / ml)
///   - "Load more" footer appears while `viewModel.hasMoreHistory` is true;
///     it's also automatically triggered when the last row appears.
struct PumpingHistoryView: View {

    @Bindable var viewModel: PumpingViewModel

    var body: some View {
        List {
            Section {
                PumpingVolumeTrendChart(points: viewModel.trendSeries30d)
                    .frame(height: 160)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if viewModel.history.isEmpty {
                Section {
                    Text("No pumping history yet. Logged sessions will appear here grouped by day.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pumpingHistoryEmptyState")
                }
            } else {
                ForEach(viewModel.history, id: \.day) { daySummary in
                    Section {
                        ForEach(daySummary.sessions) { session in
                            PumpingHistoryRow(session: session)
                                .accessibilityIdentifier("pumpingHistoryRow")
                        }
                    } header: {
                        PumpingHistoryDayHeader(summary: daySummary)
                    }
                }

                if viewModel.hasMoreHistory {
                    Section {
                        Button {
                            viewModel.loadMoreHistory()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Load more")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.pink)
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("pumpingHistoryLoadMoreButton")
                        .onAppear {
                            // Auto-expand as the user scrolls to the bottom;
                            // the button is still the a11y fallback.
                            viewModel.loadMoreHistory()
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pumping history")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("pumpingHistoryView")
        .tint(.pink)
    }
}

// MARK: - Day header

private struct PumpingHistoryDayHeader: View {
    let summary: DailyPumpingSummary

    var body: some View {
        HStack {
            Text(summary.day, style: .date)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(summary.totalVolumeMl) ml · \(summary.totalMinutes) min")
                .font(.caption)
                .foregroundStyle(.pink)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.day.formatted(date: .long, time: .omitted)), total \(summary.totalVolumeMl) millilitres, \(summary.totalMinutes) minutes")
    }
}

// MARK: - History row

private struct PumpingHistoryRow: View {
    let session: PumpingSession

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeFormatter.string(from: session.startedAt))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(sideLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.durationMinutes) min")
                    .font(.subheadline.weight(.semibold))
                if let vol = session.milkVolumeMl {
                    Text("\(vol) ml")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var sideLabel: String {
        switch session.side {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        case .none: return "—"
        }
    }
}

// MARK: - Trend chart

private struct PumpingVolumeTrendChart: View {
    let points: [DailyVolumePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("30-day volume trend")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Chart(points, id: \.day) { p in
                BarMark(
                    x: .value("Day", p.day, unit: .day),
                    y: .value("ml", p.totalVolumeMl)
                )
                .foregroundStyle(Color.pink.gradient)
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .accessibilityIdentifier("pumpingTrendChart")
            .accessibilityLabel("30-day pumping volume trend chart")
        }
    }
}

#Preview("Pumping history") {
    NavigationStack {
        PumpingHistoryView(viewModel: PumpingViewModel(
            repository: InMemoryPumpingSessionRepository(),
            clock: SystemClock()
        ))
    }
}

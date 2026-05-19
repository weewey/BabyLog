import SwiftUI
import Charts
import BabyLogCore

enum DiaperTrendRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }
    var label: String { "\(rawValue)d" }
    var days: Int { rawValue }
}

/// Stacked bar chart of daily diaper counts (wet / dirty / both) across a
/// 7, 14 or 30 day window. Views are dumb — all bucketing delegates to the
/// pure `DiaperLogAnalytics.dailyCounts` function.
struct DiaperCountsChartView: View {

    let logs: [DiaperLog]
    let now: Date
    var calendar: Calendar = .current

    @State private var range: DiaperTrendRange = .sevenDays

    private var buckets: [DiaperLogAnalytics.DailyCountsPoint] {
        DiaperLogAnalytics.dailyCounts(
            logs,
            endingOn: now,
            days: range.days,
            calendar: calendar
        )
    }

    private var totalWet:   Int { buckets.reduce(0) { $0 + $1.wet } }
    private var totalDirty: Int { buckets.reduce(0) { $0 + $1.dirty } }
    private var totalBoth:  Int { buckets.reduce(0) { $0 + $1.both } }
    private var grandTotal: Int { totalWet + totalDirty + totalBoth }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $range) {
                ForEach(DiaperTrendRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("diaperTrendRangePicker")
            .accessibilityLabel("Trend range")
            .accessibilityHint("Select a 7, 14, or 30 day window")

            if grandTotal >= 1 {
                chart
            } else {
                Text("Log diaper changes to see your trend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("diaperTrendEmptyState")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var chart: some View {
        Chart {
            ForEach(buckets, id: \.date) { bucket in
                BarMark(
                    x: .value("Date", bucket.date, unit: .day),
                    y: .value("Count", bucket.wet)
                )
                .foregroundStyle(by: .value("Type", "Wet"))

                BarMark(
                    x: .value("Date", bucket.date, unit: .day),
                    y: .value("Count", bucket.dirty)
                )
                .foregroundStyle(by: .value("Type", "Dirty"))

                BarMark(
                    x: .value("Date", bucket.date, unit: .day),
                    y: .value("Count", bucket.both)
                )
                .foregroundStyle(by: .value("Type", "Both"))
            }
        }
        .chartForegroundStyleScale([
            "Wet":   Theme.diaper.opacity(0.45),
            "Dirty": Theme.diaper,
            "Both":  Theme.diaper.opacity(0.75),
        ])
        .chartYAxisLabel("changes")
        .frame(height: 160)
        .accessibilityIdentifier("diaperTrendChart")
        .accessibilityLabel(
            "\(range.days)-day totals: \(totalWet) wet, \(totalDirty) dirty, \(totalBoth) both"
        )
    }
}

private func previewLogs() -> [DiaperLog] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    var out: [DiaperLog] = []
    let pattern: [(wet: Int, dirty: Int, both: Int)] = [
        (3, 1, 0), (2, 2, 1), (4, 0, 1), (3, 1, 0),
        (2, 1, 2), (4, 2, 0), (3, 1, 1),
    ]
    for (offset, counts) in pattern.enumerated() {
        guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
        for i in 0..<counts.wet {
            out.append(DiaperLog(id: UUID(), type: .wet,
                                 loggedAt: day.addingTimeInterval(TimeInterval(3_600 * (6 + i)))))
        }
        for i in 0..<counts.dirty {
            out.append(DiaperLog(id: UUID(), type: .dirty,
                                 loggedAt: day.addingTimeInterval(TimeInterval(3_600 * (11 + i)))))
        }
        for i in 0..<counts.both {
            out.append(DiaperLog(id: UUID(), type: .both,
                                 loggedAt: day.addingTimeInterval(TimeInterval(3_600 * (15 + i)))))
        }
    }
    return out
}

#Preview {
    DiaperCountsChartView(logs: previewLogs(), now: Date())
        .padding()
}

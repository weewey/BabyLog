import SwiftUI
import Charts
import LittleECore

enum FeedTrendRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }
    var label: String { "\(rawValue)d" }
    var days: Int { rawValue }
}

struct FeedVolumeTrendChartView: View {

    let feeds: [FeedLog]
    let pumpingSessions: [PumpingSession]
    let now: Date
    var calendar: Calendar = .current

    @State private var range: FeedTrendRange = .sevenDays

    private var buckets: [FeedLogAnalytics.DailyVolume] {
        FeedLogAnalytics.dailyVolumes(
            feeds,
            endingOn: now,
            days: range.days,
            calendar: calendar
        )
    }

    private var dailyPumpVolumes: [Date: Int] {
        FeedLogAnalytics.dailyPumpVolumes(
            pumpingSessions,
            endingOn: now,
            days: range.days,
            calendar: calendar
        )
    }

    private var nonEmptyDayCount: Int {
        buckets.filter { $0.count > 0 }.count
    }

    private var averageVolume: Int {
        let active = buckets.filter { $0.count > 0 }
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0) { $0 + $1.volumeMl }
        return total / active.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $range) {
                ForEach(FeedTrendRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("feedTrendRangePicker")
            .accessibilityLabel("Trend range")
            .accessibilityHint("Select a 7, 14, or 30 day window")

            if nonEmptyDayCount >= 2 {
                Chart(buckets, id: \.date) { bucket in
                    BarMark(
                        x: .value("Date", bucket.date, unit: .day),
                        y: .value("Volume", bucket.volumeMl)
                    )
                    .foregroundStyle(Theme.feed)
                    .annotation(position: .top, spacing: 2) {
                        if bucket.volumeMl > 0 {
                            let pumpVol = dailyPumpVolumes[bucket.date] ?? 0
                            let pct = FeedLogAnalytics.pumpMilkPercentage(
                                feedVolumeMl: bucket.volumeMl,
                                pumpVolumeMl: pumpVol
                            )
                            VStack(spacing: 0) {
                                Text("\(bucket.volumeMl)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if pumpVol > 0 {
                                    Text("\(pct)%")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.pink)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
                .chartYAxisLabel("ml")
                .frame(height: 180)
                .accessibilityIdentifier("feedTrendChart")
                .accessibilityLabel(
                    "\(range.days)-day average: \(averageVolume) millilitres per day"
                )
            } else {
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private func previewFeeds() -> [FeedLog] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    var out: [FeedLog] = []
    let pattern: [Int] = [420, 510, 480, 560, 600, 540, 620]
    for (offset, total) in pattern.enumerated() {
        guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
        let halves = [total / 2, total - total / 2]
        for (i, volume) in halves.enumerated() {
            if let feed = try? FeedLog(
                volumeMl: volume,
                loggedAt: day.addingTimeInterval(TimeInterval(3_600 * (8 + i * 4))),
                source: .bottle
            ) {
                out.append(feed)
            }
        }
    }
    return out
}

#Preview {
    FeedVolumeTrendChartView(feeds: previewFeeds(), pumpingSessions: [], now: Date())
        .padding()
}

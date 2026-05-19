import SwiftUI
import BabyLogCore

/// Feed-tab analytics. A single compact card with night vs day split,
/// inline night-cluster badge and longest-stretch line, peak-hour pills,
/// and an expandable hour-of-day strip. All logic lives in
/// `FeedLogAnalytics`; this file is a pure projection.
struct FeedClusterHeatmapView: View {

    let feeds: [FeedLog]
    let now: Date

    private var calendar: Calendar { .current }

    private var split: FeedLogAnalytics.NightDaySplit {
        FeedLogAnalytics.nightDaySplit(feeds: feeds, on: now, calendar: calendar)
    }

    private var longestStretch: TimeInterval? {
        FeedLogAnalytics.longestStretch(feeds: feeds, on: now, calendar: calendar)
    }

    private var nightClusterActive: Bool {
        FeedLogAnalytics.detectNightCluster(feeds: feeds, on: now, calendar: calendar)
    }

    private var peaks: [FeedLogAnalytics.PeakHour] {
        FeedLogAnalytics.peakHours(
            feeds: feeds,
            endingOn: now,
            days: 7,
            limit: 3,
            calendar: calendar
        )
    }

    private var heatmap: [Int] {
        FeedLogAnalytics.hourlyHeatmap(
            feeds: feeds,
            endingOn: now,
            days: 7,
            calendar: calendar
        )
    }

    private var totalMl: Int { split.night.volumeMl + split.day.volumeMl }
    private var nightPct: Int {
        guard totalMl > 0 else { return 0 }
        return Int((Double(split.night.volumeMl) / Double(totalMl) * 100).rounded())
    }
    private var dayPct: Int {
        guard totalMl > 0 else { return 0 }
        return max(0, 100 - nightPct)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            nightDayRow
            if let longestStretch {
                longestStretchLabel(longestStretch)
            }
            if !peaks.isEmpty {
                peakRow
            }
            heatmapGrid
        }
        .padding(Theme.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.feed.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack {
            Text("Night vs Day")
                .font(.headline)
            Spacer()
            if nightClusterActive {
                Badge(
                    systemImage: "moon.stars.fill",
                    text: "Night cluster",
                    tint: Theme.feed
                )
                .accessibilityIdentifier("feedNightClusterBadge")
            }
        }
    }

    private var nightDayRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            halfColumn(
                title: "NIGHT",
                subtitle: "10pm–7am",
                icon: "moon.fill",
                total: split.night,
                percent: nightPct
            )
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: 48)
            halfColumn(
                title: "DAY",
                subtitle: "7am–10pm",
                icon: "sun.max.fill",
                total: split.day,
                percent: dayPct
            )
        }
    }

    private func halfColumn(
        title: String,
        subtitle: String,
        icon: String,
        total: FeedLogAnalytics.DailyTotal,
        percent: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.feed)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
            Text("\(total.volumeMl) ml")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .accessibilityLabel("\(title.lowercased()) \(total.volumeMl) millilitres")
            Text("\(total.count) feed\(total.count == 1 ? "" : "s") · \(percent)%")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func longestStretchLabel(_ seconds: TimeInterval) -> some View {
        Label(
            "Longest stretch today: \(formatDuration(seconds))",
            systemImage: "hourglass"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("feedLongestStretch")
    }

    private var peakRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PEAK HOURS · 7d")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            HStack(spacing: 6) {
                ForEach(peaks, id: \.hour) { peak in
                    Text("\(hourLabel(peak.hour)) · \(peak.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.feed.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.feed)
                        .accessibilityLabel("\(hourLabel(peak.hour)), \(peak.count) feeds")
                }
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("feedPeakHours")
    }

    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FEEDING HEATMAP · 7d")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("count by hour")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { col in
                            heatmapCell(hour: row * 8 + col)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heatmapA11yLabel)
        .accessibilityIdentifier("feedHeatmapGrid")
    }

    private func heatmapCell(hour: Int) -> some View {
        let count = heatmap[hour]
        return VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cellColor(count))
                    .aspectRatio(1, contentMode: .fit)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(cellTextColor(count))
                }
            }
            Text(shortHourLabel(hour))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func cellTextColor(_ count: Int) -> Color {
        guard heatmapMax > 0, count > 0 else { return .secondary }
        // The ramp below goes dark-on-cool and light-on-warm ends; white
        // reads cleanly on every band except the lowest (pale blue), which
        // falls back to the feed tint for contrast.
        let ratio = Double(count) / Double(heatmapMax)
        return ratio < 0.2 ? Theme.feed : .white
    }

    private var heatmapMax: Int { heatmap.max() ?? 0 }

    /// Sequential cool→warm ramp keyed to the hour's intensity relative to
    /// the busiest hour in the window. Zero-count cells stay neutral so the
    /// eye doesn't confuse "no data" with "low count".
    private func cellColor(_ count: Int) -> Color {
        guard heatmapMax > 0, count > 0 else {
            return Color(.tertiarySystemBackground)
        }
        let ratio = Double(count) / Double(heatmapMax)
        switch ratio {
        case ..<0.2:  return Color(red: 0.30, green: 0.56, blue: 0.92) // pale blue
        case ..<0.4:  return Color(red: 0.35, green: 0.73, blue: 0.80) // teal
        case ..<0.6:  return Color(red: 0.45, green: 0.78, blue: 0.45) // green
        case ..<0.8:  return Color(red: 0.98, green: 0.75, blue: 0.30) // amber
        default:      return Color(red: 0.92, green: 0.35, blue: 0.32) // red
        }
    }

    private var heatmapA11yLabel: String {
        let top = heatmap.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(3)
            .map { "\(hourLabel($0.offset)) \($0.element)" }
            .joined(separator: ", ")
        return "Feeding pattern last 7 days. Busiest hours: \(top.isEmpty ? "none yet" : top)."
    }
}

private func shortHourLabel(_ hour: Int) -> String {
    // Compact labels like "12a", "1a", "12p", "11p"
    let h12 = hour % 12 == 0 ? 12 : hour % 12
    let suffix = hour < 12 ? "a" : "p"
    return "\(h12)\(suffix)"
}

private func hourLabel(_ hour: Int) -> String {
    let comps = DateComponents(hour: hour)
    guard let d = Calendar.current.date(from: comps) else { return "\(hour)" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("ha")
    return f.string(from: d).lowercased()
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    if total < 60 { return "<1m" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let rem = minutes % 60
    return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
}

#Preview("Compact analytics card") {
    let now = Date()
    let cal = Calendar.current
    let startOfToday = cal.startOfDay(for: now)
    let feeds: [FeedLog] = {
        var out: [FeedLog] = []
        for (h, v) in [(1, 80), (2, 90), (3, 70), (9, 110), (13, 100), (17, 120)] {
            if let t = cal.date(byAdding: .hour, value: h, to: startOfToday),
               let f = try? FeedLog(volumeMl: v, loggedAt: t, source: .bottle) {
                out.append(f)
            }
        }
        for d in 1...6 {
            for h in [3, 9, 14, 21] {
                if let t = cal.date(byAdding: .day, value: -d, to: startOfToday),
                   let t2 = cal.date(byAdding: .hour, value: h, to: t),
                   let f = try? FeedLog(volumeMl: 80, loggedAt: t2, source: .bottle) {
                    out.append(f)
                }
            }
        }
        return out
    }()
    return FeedClusterHeatmapView(feeds: feeds, now: now)
        .padding()
}

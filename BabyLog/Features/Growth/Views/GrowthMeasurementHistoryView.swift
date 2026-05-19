import SwiftUI
import LittleECore

struct GrowthMeasurementHistoryView: View {

    let entries: [GrowthMeasurement]

    var body: some View {
        if entries.isEmpty {
            WarmEmptyState(
                title: "No Measurements Yet",
                message: "Log a weight, height, or head circumference above.",
                systemImage: "ruler.fill",
                tint: Theme.growth
            )
            .accessibilityIdentifier("growthEmptyState")
        } else {
            List {
                ForEach(entries, id: \.id.value) { entry in
                    GrowthMeasurementRow(entry: entry)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("growthHistoryList")
        }
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

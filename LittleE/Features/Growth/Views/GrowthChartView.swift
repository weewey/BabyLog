import SwiftUI
import Charts
import LittleECore

enum GrowthMetric: String, CaseIterable, Identifiable {
    case weight, height, head
    var id: String { rawValue }
    var label: String {
        switch self {
        case .weight: "Weight"
        case .height: "Height"
        case .head:   "Head"
        }
    }
    var unit: String {
        switch self {
        case .weight: "kg"
        case .height: "cm"
        case .head:   "cm"
        }
    }
    var tint: Color {
        switch self {
        case .weight: .orange
        case .height: .green
        case .head:   .teal
        }
    }
}

struct GrowthChartView: View {

    let entries: [GrowthMeasurement]
    @State private var metric: GrowthMetric = .weight

    private var points: [(date: Date, value: Double)] {
        entries.compactMap { entry in
            let v: Double?
            switch metric {
            case .weight: v = entry.weightGrams.map { Double($0) / 1000.0 }
            case .height: v = entry.heightCm
            case .head:   v = entry.headCircumferenceCm
            }
            guard let value = v else { return nil }
            return (entry.date, value)
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Metric", selection: $metric) {
                ForEach(GrowthMetric.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("growthMetricPicker")

            if points.count >= 2 {
                Chart(points, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(metric.label, point.value)
                    )
                    .foregroundStyle(metric.tint)
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(metric.label, point.value)
                    )
                    .foregroundStyle(metric.tint)
                }
                .chartYAxisLabel(metric.unit)
                .frame(height: 160)
                .accessibilityIdentifier("growthChart")
            } else {
                Text("Add at least two \(metric.label.lowercased()) measurements to see a trend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private func previewEntries() -> [GrowthMeasurement] {
    let base = Date()
    var out: [GrowthMeasurement] = []
    for i in 0..<5 {
        if let m = try? GrowthMeasurement(
            date: base.addingTimeInterval(Double(-i) * 86_400 * 7),
            weightGrams: 4000 + i * 250,
            heightCm: 52.0 + Double(i) * 1.5,
            headCircumferenceCm: 36.0 + Double(i) * 0.4
        ) {
            out.append(m)
        }
    }
    return out
}

#Preview {
    GrowthChartView(entries: previewEntries())
}

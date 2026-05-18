import SwiftUI

/// Local-only dashboard showing Gemma 4 generation latency. Reached from
/// Settings → Chat → "Gemma latency". Reads from `GemmaTelemetry.shared`,
/// which is populated by `Gemma4MLXChatSession` on every turn.
struct GemmaTelemetryView: View {

    @Bindable var telemetry: GemmaTelemetry

    var body: some View {
        List {
            Section("Medians (last \(telemetry.samples.count) turns)") {
                metricRow(
                    label: "First token",
                    value: telemetry.medianFirstTokenSeconds,
                    format: .seconds
                )
                metricRow(
                    label: "Total turn",
                    value: telemetry.medianTotalSeconds,
                    format: .seconds
                )
                metricRow(
                    label: "Decode rate",
                    value: telemetry.medianTokensPerSecond,
                    format: .tokensPerSecond
                )
                metricRow(
                    label: "Last cold-load",
                    value: telemetry.lastLoadSeconds,
                    format: .seconds
                )
            }

            Section("Samples") {
                if telemetry.samples.isEmpty {
                    Text("No turns recorded yet. Send a message in the chat tab to populate this dashboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(telemetry.samples.reversed()) { sample in
                        sampleRow(sample)
                    }
                }
            }
        }
        .navigationTitle("Gemma latency")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { telemetry.clear() }
                    .disabled(telemetry.samples.isEmpty)
                    .accessibilityHint("Clear all recorded Gemma latency samples")
            }
        }
    }

    // MARK: - Rows

    private func metricRow(
        label: String,
        value: Double?,
        format: MetricFormat
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(format.render(value))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }

    private func sampleRow(_ s: GemmaTelemetry.Sample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if s.toolCallFired {
                    Text("tool")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                metricChip("TTF", MetricFormat.seconds.render(s.firstTokenSeconds))
                metricChip("Total", MetricFormat.seconds.render(s.totalSeconds))
                metricChip(
                    "Rate",
                    s.decodeSeconds > 0.01 && s.tokensOut > 0
                        ? MetricFormat.tokensPerSecond.render(Double(s.tokensOut) / s.decodeSeconds)
                        : "—"
                )
            }
            HStack(spacing: 12) {
                Text("hist \(s.historyCount)")
                Text("chunks \(s.tokensOut)")
                if let load = s.loadSeconds {
                    Text("load \(MetricFormat.seconds.render(load))")
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func metricChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
        }
    }
}

private enum MetricFormat {
    case seconds
    case tokensPerSecond

    func render(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch self {
        case .seconds:
            if value < 1 {
                return String(format: "%d ms", Int(value * 1000))
            }
            return String(format: "%.2f s", value)
        case .tokensPerSecond:
            return String(format: "%.1f tok/s", value)
        }
    }
}

#Preview {
    NavigationStack {
        GemmaTelemetryView(telemetry: {
            let t = GemmaTelemetry()
            t.record(.init(
                timestamp: Date(),
                loadSeconds: 3.2,
                firstTokenSeconds: 0.84,
                decodeSeconds: 1.6,
                totalSeconds: 2.44,
                tokensOut: 32,
                historyCount: 3,
                toolCallFired: true
            ))
            return t
        }())
    }
}

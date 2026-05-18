import SwiftUI

/// Local-only debug pane that shows the rolling voice capture log.
/// Reached from Settings → "Voice debug" toggle.
struct VoiceTelemetryView: View {

    let telemetry: VoiceTelemetry

    var body: some View {
        List {
            if telemetry.entries.isEmpty {
                Text("No voice events yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No voice events yet")
            } else {
                ForEach(telemetry.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.transcript)
                            .font(.body)
                        Text(entry.parsed)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Voice debug")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { telemetry.clear() }
                    .accessibilityHint("Clear all logged voice events")
            }
        }
    }
}

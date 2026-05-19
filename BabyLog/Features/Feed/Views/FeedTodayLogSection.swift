import SwiftUI
import LittleECore

struct FeedTodayLogSection: View {

    let entries: [FeedLog]
    var onDelete: ((UUID) -> Void)? = nil

    var body: some View {
        if !entries.isEmpty {
            Section(header: Text("Today")) {
                ForEach(entries) { entry in
                    FeedTodayRow(entry: entry)
                        .accessibilityIdentifier("feedTodayRow_\(entry.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete?(entry.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("deleteFeed_\(entry.id)")
                        }
                }
            }
        }
    }
}

private struct FeedTodayRow: View {

    let entry: FeedLog

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(entry.volumeMl)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Text("ml")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(RelativeTime.shortLabel(for: entry.loggedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notes = entry.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(entry.loggedAt, style: .time)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.volumeMl) ml feed")
        .accessibilityHint("Logged \(RelativeTime.shortLabel(for: entry.loggedAt))")
    }
}

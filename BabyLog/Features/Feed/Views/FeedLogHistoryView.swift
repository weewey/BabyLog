import SwiftUI
import BabyLogCore

/// Renders feed-log history as one or more `Section`s. Must be embedded
/// inside a parent `List`.
struct FeedLogHistoryView: View {

    let groupedEntries: [(Date, [FeedLog])]
    var onDelete: ((UUID) -> Void)? = nil

    var body: some View {
        if groupedEntries.isEmpty {
            Section {
                WarmEmptyState(
                    title: "No Feeds Yet",
                    message: "Tap + to log a feed.",
                    systemImage: "cup.and.heat.waves",
                    tint: Theme.feed
                )
                .accessibilityIdentifier("emptyState")
                .frame(height: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else {
            ForEach(groupedEntries, id: \.0) { day, entries in
                Section(header: Text(RelativeTime.sectionLabel(for: day))) {
                    ForEach(entries) { entry in
                        FeedLogRow(entry: entry)
                            .accessibilityIdentifier("feedRow_\(entry.id)")
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
}

private struct FeedLogRow: View {

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

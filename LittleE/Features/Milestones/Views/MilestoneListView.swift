import SwiftUI
import LittleECore

/// Renders milestone history as one or more `Section`s. Must be embedded
/// inside a parent `List`.
struct MilestoneListView: View {

    let entries: [Milestone]
    var onDelete: ((UUID) -> Void)? = nil

    var body: some View {
        if entries.isEmpty {
            Section {
                WarmEmptyState(
                    title: "No Milestones Yet",
                    message: "Tap + to log first smiles, steps, words — anything worth celebrating.",
                    systemImage: "star.fill",
                    tint: Theme.milestone
                )
                .accessibilityIdentifier("milestoneEmptyState")
                .frame(height: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else {
            Section("History") {
                ForEach(entries) { entry in
                    MilestoneRow(entry: entry)
                        .accessibilityIdentifier("milestoneRow_\(entry.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete?(entry.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
}

private struct MilestoneRow: View {
    let entry: Milestone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text(entry.title)
                    .font(.headline)
                Spacer()
                Text(entry.achievedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = entry.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

import SwiftUI
import LittleECore

/// Renders diaper-log history as one or more `Section`s. Must be embedded
/// inside a parent `List`.
struct DiaperLogHistoryView: View {

    let groupedEntries: [(Date, [DiaperLog])]
    var onDelete: ((UUID) -> Void)? = nil

    var body: some View {
        if groupedEntries.isEmpty {
            Section {
                WarmEmptyState(
                    title: "No Diaper Changes Yet",
                    message: "Tap + to log a diaper change.",
                    systemImage: "moon.zzz.fill",
                    tint: Theme.diaper
                )
                .accessibilityIdentifier("emptyState")
                .frame(height: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else {
            ForEach(groupedEntries, id: \.0) { day, entries in
                Section(header: Text(day, style: .date)) {
                    ForEach(entries) { entry in
                        DiaperLogRow(entry: entry)
                            .accessibilityIdentifier("diaperRow_\(entry.id)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDelete?(entry.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityIdentifier("deleteDiaper_\(entry.id)")
                            }
                    }
                }
            }
        }
    }
}

private struct DiaperLogRow: View {

    let entry: DiaperLog

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Badge(
                    systemImage: iconName(for: entry.type),
                    text: displayName(for: entry.type),
                    tint: tint(for: entry.type)
                )
                HStack(spacing: 6) {
                    Text(RelativeTime.shortLabel(for: entry.loggedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let notes = entry.notes, !notes.isEmpty {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
        .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        var parts = ["\(displayName(for: entry.type)) diaper change, \(RelativeTime.shortLabel(for: entry.loggedAt))"]
        if let notes = entry.notes, !notes.isEmpty {
            parts.append(notes)
        }
        return parts.joined(separator: ", ")
    }

    private func iconName(for type: DiaperType) -> String {
        switch type {
        case .wet: return "drop.fill"
        case .dirty: return "leaf.fill"
        case .both: return "drop.triangle.fill"
        }
    }

    private func displayName(for type: DiaperType) -> String {
        switch type {
        case .wet: return "Wet"
        case .dirty: return "Dirty"
        case .both: return "Both"
        }
    }

    private func tint(for type: DiaperType) -> Color {
        switch type {
        case .wet: return .blue
        case .dirty: return .brown
        case .both: return .purple
        }
    }
}

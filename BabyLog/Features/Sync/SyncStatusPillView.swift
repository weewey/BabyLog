import SwiftUI
import LittleECore

/// Compact status pill for the Settings screen. Pure projection of a
/// `SyncStatus` — all copy comes from `SyncStatus.pillLabel(...)` in Core.
///
/// When the status is `.idle` the pill collapses to `EmptyView` — a
/// paused pill reads as "broken" to users, and Designer's call is to
/// hide the affordance entirely when no peer is nearby.
struct SyncStatusPillView: View {

    let status: SyncStatus
    let now: Date

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .searching, .connected, .permissionDenied, .unavailable:
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .symbolEffect(.rotate, options: .repeating, isActive: isTransferring)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.15))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Current peer sync status"))
        .accessibilityIdentifier("syncStatusPill")
    }

    private var label: String {
        status.pillLabel(now: now, relativeFormatter: Self.relativeLabel)
    }

    private var isTransferring: Bool {
        if case .connected(_, let isTransferring, _) = status {
            return isTransferring
        }
        return false
    }

    private var icon: String {
        switch status {
        case .idle: return "moon.zzz"
        case .searching: return "dot.radiowaves.left.and.right"
        case .connected(_, let isTransferring, _):
            return isTransferring ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
        case .permissionDenied: return "lock.slash"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch status {
        case .idle: return .secondary
        case .searching: return .blue
        case .connected: return .green
        case .permissionDenied: return .orange
        case .unavailable: return .red
        }
    }

    private static func relativeLabel(_ last: Date, _ now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: last, relativeTo: now)
    }
}

#Preview("Idle (hidden)") {
    SyncStatusPillView(status: .idle, now: Date())
}

#Preview("Searching") {
    SyncStatusPillView(status: .searching, now: Date())
}

#Preview("Connected") {
    SyncStatusPillView(
        status: .connected(peerName: "Mum's iPhone", isTransferring: false, lastSyncedAt: Date().addingTimeInterval(-180)),
        now: Date()
    )
}

#Preview("Syncing") {
    SyncStatusPillView(
        status: .connected(peerName: "Mum's iPhone", isTransferring: true, lastSyncedAt: nil),
        now: Date()
    )
}

#Preview("Permission denied") {
    SyncStatusPillView(status: .permissionDenied, now: Date())
}

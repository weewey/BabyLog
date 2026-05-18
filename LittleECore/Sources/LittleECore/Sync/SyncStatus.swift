import Foundation

/// Publishable status of the peer sync subsystem. The Settings pill
/// projects this enum directly into UI copy — no conditional on domain
/// state lives in the view.
public enum SyncStatus: Equatable, Sendable {

    /// Service is stopped (e.g. user toggled sync off or we haven't
    /// yet started browsing).
    case idle

    /// Advertising / browsing but no peer found yet.
    case searching

    /// Actively connected to a named peer. `isTransferring` flips true
    /// while a handshake or delta transfer is in flight — the pill uses
    /// it to swap in a rotating "syncing" glyph.
    case connected(peerName: String, isTransferring: Bool, lastSyncedAt: Date?)

    /// Local network / Bluetooth permission was denied by the user.
    /// The pill asks them to re-enable it in Settings.
    case permissionDenied

    /// Service hit a recoverable error while advertising or browsing.
    case unavailable(reason: String)
}

public extension SyncStatus {

    /// Short human label for the Settings pill. Lives in Core so it's
    /// unit-testable and the SwiftUI view can project it directly.
    func pillLabel(now: Date, relativeFormatter: (Date, Date) -> String) -> String {
        switch self {
        case .idle:
            return "Sync off"
        case .searching:
            return "Searching for peer..."
        case .connected(let peerName, let isTransferring, let lastSyncedAt):
            if isTransferring {
                return "Syncing with \(peerName)..."
            }
            if let lastSyncedAt {
                return "Connected to \(peerName) · synced \(relativeFormatter(lastSyncedAt, now))"
            }
            return "Connected to \(peerName)"
        case .permissionDenied:
            return "Permission denied"
        case .unavailable(let reason):
            return "Not reachable — \(reason)"
        }
    }
}

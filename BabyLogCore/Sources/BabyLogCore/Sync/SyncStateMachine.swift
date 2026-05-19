import Foundation

/// Serialised state machine for the peer sync subsystem.
///
/// `MultipeerSyncService` receives delegate callbacks on an opaque
/// Multipeer-owned queue and fans them into Swift concurrency. Without
/// ordering those transitions, two near-simultaneous state changes can
/// interleave and leave `status` stale — e.g. a `notConnected` arriving
/// after a fresh `connected` silently reverts the pill to `.searching`.
///
/// This actor fixes that by:
///
/// 1. Serialising *all* transitions (actor isolation).
/// 2. Tagging each transition with a caller-supplied monotonic
///    sequence number and dropping any transition whose sequence is
///    lower than the last one applied. The caller stamps the sequence
///    synchronously on the delegate queue, so ordering is captured at
///    the boundary — not lost when we jump threads.
///
/// Transitions are described by `SyncTransition`, a deliberately small
/// vocabulary that matches what the Multipeer delegate surface gives us.
public actor SyncStateMachine {

    /// Current status, safe to read from any isolation.
    public private(set) var status: SyncStatus = .idle

    /// Highest sequence number that has actually mutated `status`.
    /// A transition with a lower sequence is stale and ignored.
    private var lastAppliedSequence: UInt64 = 0

    public init(initial: SyncStatus = .idle) {
        self.status = initial
    }

    /// Apply a delegate-originated transition. Stale transitions
    /// (`sequence <= lastAppliedSequence`) are dropped.
    public func apply(sequence: UInt64, transition: SyncTransition) {
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence
        status = Self.reduce(status, transition)
    }

    /// Flip the `isTransferring` flag on a connected state. No-op in
    /// any other state. Not sequenced — transfer markers are strictly
    /// paired with the actor-serialised send/receive path, so they
    /// cannot race with delegate callbacks.
    public func markTransferring(_ isTransferring: Bool) {
        guard case let .connected(peerName, _, lastSyncedAt) = status else { return }
        status = .connected(
            peerName: peerName,
            isTransferring: isTransferring,
            lastSyncedAt: lastSyncedAt
        )
    }

    /// Record a successful sync, clearing the transferring flag and
    /// stamping the last-synced timestamp. No-op if not connected.
    public func recordSync(at timestamp: Date) {
        guard case let .connected(peerName, _, _) = status else { return }
        status = .connected(
            peerName: peerName,
            isTransferring: false,
            lastSyncedAt: timestamp
        )
    }

    // MARK: - Reducer

    private static func reduce(_ current: SyncStatus, _ transition: SyncTransition) -> SyncStatus {
        switch transition {
        case .idle:
            return .idle
        case .searching:
            return .searching
        case let .connected(peerName, isTransferring):
            // Preserve lastSyncedAt across a reconnect to the same peer
            // so the pill doesn't flicker back to "Connected" without a
            // relative timestamp.
            if case let .connected(existingName, _, lastSyncedAt) = current,
               existingName == peerName {
                return .connected(
                    peerName: peerName,
                    isTransferring: isTransferring,
                    lastSyncedAt: lastSyncedAt
                )
            }
            return .connected(peerName: peerName, isTransferring: isTransferring, lastSyncedAt: nil)
        case let .permissionDenied:
            return .permissionDenied
        case let .unavailable(reason):
            return .unavailable(reason: reason)
        }
    }
}

/// Vocabulary of state changes the Multipeer transport can announce.
public enum SyncTransition: Equatable, Sendable {
    case idle
    case searching
    case connected(peerName: String, isTransferring: Bool)
    case permissionDenied
    case unavailable(reason: String)
}

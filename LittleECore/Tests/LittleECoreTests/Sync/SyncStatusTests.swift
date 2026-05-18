import Foundation
import Testing
@testable import LittleECore

@Suite("SyncStatus")
struct SyncStatusTests {

    private func fixedFormatter(_ last: Date, _ now: Date) -> String {
        let delta = Int(now.timeIntervalSince(last))
        return "\(delta)s ago"
    }

    @Test("idle label says sync off")
    func idleLabel() {
        let label = SyncStatus.idle.pillLabel(now: .distantPast, relativeFormatter: fixedFormatter)
        #expect(label == "Sync off")
    }

    @Test("searching label mentions peer search")
    func searchingLabel() {
        let label = SyncStatus.searching.pillLabel(now: .distantPast, relativeFormatter: fixedFormatter)
        #expect(label == "Searching for peer...")
    }

    @Test("connected label includes peer name and relative sync time")
    func connectedLabelWithLastSync() {
        let now = Date(timeIntervalSince1970: 1_000)
        let last = Date(timeIntervalSince1970: 997)
        let status = SyncStatus.connected(peerName: "Mum's iPhone", isTransferring: false, lastSyncedAt: last)

        let label = status.pillLabel(now: now, relativeFormatter: fixedFormatter)

        #expect(label == "Connected to Mum's iPhone · synced 3s ago")
    }

    @Test("connected label without last sync time omits the suffix")
    func connectedLabelWithoutLastSync() {
        let status = SyncStatus.connected(peerName: "Dad's iPhone", isTransferring: false, lastSyncedAt: nil)

        let label = status.pillLabel(now: Date(), relativeFormatter: fixedFormatter)

        #expect(label == "Connected to Dad's iPhone")
    }

    @Test("connected label while transferring shows syncing copy")
    func connectedLabelWhileTransferring() {
        let status = SyncStatus.connected(peerName: "Mum's iPhone", isTransferring: true, lastSyncedAt: nil)

        let label = status.pillLabel(now: Date(), relativeFormatter: fixedFormatter)

        #expect(label == "Syncing with Mum's iPhone...")
    }

    @Test("permission denied label is explicit")
    func permissionDeniedLabel() {
        let label = SyncStatus.permissionDenied.pillLabel(now: .distantPast, relativeFormatter: fixedFormatter)
        #expect(label == "Permission denied")
    }

    @Test("unavailable label includes reason")
    func unavailableLabel() {
        let label = SyncStatus.unavailable(reason: "bluetooth off")
            .pillLabel(now: .distantPast, relativeFormatter: fixedFormatter)
        #expect(label == "Not reachable — bluetooth off")
    }
}

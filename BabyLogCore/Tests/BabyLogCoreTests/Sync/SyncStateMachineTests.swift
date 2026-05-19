import Foundation
import Testing
@testable import BabyLogCore

@Suite("SyncStateMachine")
struct SyncStateMachineTests {

    @Test("initial status is idle")
    func initialIsIdle() async {
        let machine = SyncStateMachine()

        let status = await machine.status

        #expect(status == .idle)
    }

    @Test("applying a higher-sequence transition updates status")
    func higherSequenceWins() async {
        let machine = SyncStateMachine()

        await machine.apply(sequence: 1, transition: .searching)
        await machine.apply(sequence: 2, transition: .connected(peerName: "Mum", isTransferring: false))

        let status = await machine.status
        #expect(status == .connected(peerName: "Mum", isTransferring: false, lastSyncedAt: nil))
    }

    // The race-fix test: a stale `.notConnected` arriving after a
    // fresh `.connected` must not revert the pill to searching.
    @Test("stale lower-sequence transition does not overwrite newer state")
    func staleTransitionIgnored() async {
        let machine = SyncStateMachine()

        // Arrange: two delegate callbacks stamped with sequences 1 and 2
        // on the delegate queue, in order.
        //
        // Act: deliver them out of order — the older seq=1 arrives AFTER
        // seq=2. Without the fix, seq=1's .searching clobbers seq=2's
        // .connected and the pill reverts.
        await machine.apply(sequence: 2, transition: .connected(peerName: "Mum", isTransferring: false))
        await machine.apply(sequence: 1, transition: .searching)

        // Assert: the final state reflects the newest input (seq=2).
        let status = await machine.status
        #expect(status == .connected(peerName: "Mum", isTransferring: false, lastSyncedAt: nil))
    }

    @Test("mark transferring toggles the connected state flag")
    func markTransferring() async {
        let machine = SyncStateMachine()

        await machine.apply(sequence: 1, transition: .connected(peerName: "Mum", isTransferring: false))
        await machine.markTransferring(true)

        let status = await machine.status
        if case let .connected(_, isTransferring, _) = status {
            #expect(isTransferring == true)
        } else {
            Issue.record("expected connected state, got \(status)")
        }
    }

    @Test("mark transferring is a no-op when not connected")
    func markTransferringNoopWhenIdle() async {
        let machine = SyncStateMachine()

        await machine.markTransferring(true)

        let status = await machine.status
        #expect(status == .idle)
    }
}

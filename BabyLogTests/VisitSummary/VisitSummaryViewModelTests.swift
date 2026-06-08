import XCTest
import BabyLogCore
@testable import BabyLog

@MainActor
final class VisitSummaryViewModelTests: XCTestCase {

    private final class FakeProfileRepo: ChildProfileRepository, @unchecked Sendable {
        var profile: ChildProfile?
        init(_ profile: ChildProfile?) { self.profile = profile }
        func load() async throws -> ChildProfile? { profile }
        func save(_ profile: ChildProfile) async throws { self.profile = profile }
    }

    private final class ThrowingFeedRepo: FeedLogRepository, @unchecked Sendable {
        struct Boom: Error {}
        func save(_ feed: FeedLog) async throws {}
        func all() async throws -> [FeedLog] { throw Boom() }
        func delete(id: UUID) async throws {}
    }

    private func makeVM(
        feedRepo: any FeedLogRepository,
        appointments: [MedicalAppointment] = [],
        chatFactory: (any ChatSessionFactory)? = nil
    ) async -> VisitSummaryViewModel {
        let apptRepo = InMemoryMedicalAppointmentRepository()
        for a in appointments { try? await apptRepo.save(a) }
        let profile = try! ChildProfile(name: "Ethan", dateOfBirth: Date(timeIntervalSince1970: 0))
        return VisitSummaryViewModel(
            profileRepository: FakeProfileRepo(profile),
            feedRepository: feedRepo,
            diaperRepository: InMemoryDiaperLogRepository(),
            growthRepository: InMemoryGrowthMeasurementRepository(),
            pumpingRepository: InMemoryPumpingSessionRepository(),
            milestoneRepository: InMemoryMilestoneRepository(),
            appointmentRepository: apptRepo,
            chatSessionFactory: chatFactory
        )
    }

    private func waitUntil(
        _ check: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out")
    }

    func test_load_buildsSummaryAndShareText() async {
        let feedRepo = InMemoryFeedLogRepository()
        try? await feedRepo.save(try! FeedLog(volumeMl: 120, loggedAt: Date(), source: .bottle))
        let vm = await makeVM(feedRepo: feedRepo)

        await vm.load()

        XCTAssertEqual(vm.state, .loaded)
        XCTAssertNotNil(vm.summary)
        XCTAssertEqual(vm.summary?.childName, "Ethan")
        XCTAssertTrue(vm.shareText.contains("visit summary"))
        XCTAssertTrue(vm.shareText.contains("FEEDS"))
    }

    func test_load_repositoryFailure_setsFailedState() async {
        let vm = await makeVM(feedRepo: ThrowingFeedRepo())

        await vm.load()

        guard case .failed = vm.state else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertNil(vm.summary)
        XCTAssertTrue(vm.shareText.isEmpty)
    }

    // MARK: - V2 narration

    func test_load_narratesViaChatFactory() async {
        let factory = FakeChatSessionFactory { _ in
            .tokens(["Ethan ", "is ", "thriving."], perTokenDelay: .milliseconds(0))
        }
        let vm = await makeVM(feedRepo: InMemoryFeedLogRepository(), chatFactory: factory)

        await vm.load()
        await waitUntil { !vm.isNarrating }

        XCTAssertEqual(vm.narration, "Ethan is thriving.")
        XCTAssertEqual(vm.state, .loaded)
    }

    func test_load_narrationFailure_leavesNarrationEmptyButSummaryLoaded() async {
        struct Boom: Error {}
        let factory = FakeChatSessionFactory { _ in .failsAfter(0, error: Boom()) }
        let vm = await makeVM(feedRepo: InMemoryFeedLogRepository(), chatFactory: factory)

        await vm.load()
        await waitUntil { !vm.isNarrating }

        XCTAssertEqual(vm.narration, "")
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertNotNil(vm.summary)
    }

    func test_load_withoutChatFactory_doesNotNarrate() async {
        let vm = await makeVM(feedRepo: InMemoryFeedLogRepository(), chatFactory: nil)

        await vm.load()

        XCTAssertFalse(vm.isNarrating)
        XCTAssertEqual(vm.narration, "")
    }
}

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
        feeds: [FeedLog] = []
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
            appointmentRepository: apptRepo
        )
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
}

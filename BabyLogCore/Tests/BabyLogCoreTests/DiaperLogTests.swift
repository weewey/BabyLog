import XCTest
@testable import BabyLogCore

final class DiaperLogTests: XCTestCase {

    // MARK: - Test infrastructure

    /// Deterministic date source injected into table-driven tests.
    private struct FixedClock {
        let date: Date
        func now() -> Date { date }
    }

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: - DiaperType raw-value recognition

    func test_diaperType_rawValue_wet_isRecognised() {
        XCTAssertEqual(DiaperType(rawValue: "wet"), .wet)
    }

    func test_diaperType_rawValue_dirty_isRecognised() {
        XCTAssertEqual(DiaperType(rawValue: "dirty"), .dirty)
    }

    func test_diaperType_rawValue_both_isRecognised() {
        XCTAssertEqual(DiaperType(rawValue: "both"), .both)
    }

    // MARK: - DiaperLog: valid construction for every DiaperType

    func test_diaperLog_init_wet_storesType() {
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: .distantPast)
        XCTAssertEqual(log.type, .wet)
    }

    func test_diaperLog_init_dirty_storesType() {
        let log = DiaperLog(id: UUID(), type: .dirty, loggedAt: .distantPast)
        XCTAssertEqual(log.type, .dirty)
    }

    func test_diaperLog_init_both_storesType() {
        let log = DiaperLog(id: UUID(), type: .both, loggedAt: .distantPast)
        XCTAssertEqual(log.type, .both)
    }

    // MARK: - DiaperLog: notes

    func test_diaperLog_withNotes_storesNotes() {
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: .distantPast, notes: "mild rash")
        XCTAssertEqual(log.notes, "mild rash")
    }

    func test_diaperLog_withoutNotes_notesIsNil() {
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: .distantPast)
        XCTAssertNil(log.notes)
    }

    // MARK: - DiaperLog: raw-value init validation

    func test_diaperLog_rawValueInit_validRawValue_succeeds() throws {
        let log = try DiaperLog(id: UUID(), typeRawValue: "dirty", loggedAt: .distantPast)
        XCTAssertEqual(log.type, .dirty)
    }

    func test_diaperLog_rawValueInit_unknownRawValue_throwsInvalidType() {
        // Arrange
        var caught: DiaperLogError?
        // Act
        do {
            _ = try DiaperLog(id: UUID(), typeRawValue: "soiled", loggedAt: .distantPast)
            XCTFail("Expected DiaperLogError.invalidType to be thrown")
        } catch let e {
            caught = e
        }
        // Assert
        XCTAssertEqual(caught, .invalidType("soiled"))
    }

    func test_diaperLog_rawValueInit_emptyString_throwsInvalidType() {
        var caught: DiaperLogError?
        do {
            _ = try DiaperLog(id: UUID(), typeRawValue: "", loggedAt: .distantPast)
        } catch let e {
            caught = e
        }
        XCTAssertEqual(caught, .invalidType(""))
    }

    // MARK: - InMemoryDiaperLogRepository: round-trip

    func test_repository_save_andAll_returnsSavedEntry() async throws {
        // Arrange
        let repo = InMemoryDiaperLogRepository()
        let log  = DiaperLog(id: UUID(), type: .wet, loggedAt: .distantPast)
        // Act
        try await repo.save(log)
        let all = try await repo.all()
        // Assert
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, log.id)
    }

    // MARK: - InMemoryDiaperLogRepository: delete

    func test_repository_delete_removesEntry() async throws {
        let repo = InMemoryDiaperLogRepository()
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: .distantPast)
        try await repo.save(log)

        try await repo.delete(id: log.id)

        let all = try await repo.all()
        XCTAssertTrue(all.isEmpty)
    }

    func test_repository_delete_unknownId_isNoOp() async throws {
        let repo = InMemoryDiaperLogRepository()
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: .distantPast)
        try await repo.save(log)

        try await repo.delete(id: UUID())

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
    }

    func test_repository_all_returnsNewestFirst() async throws {
        // Arrange
        let repo  = InMemoryDiaperLogRepository()
        let older = DiaperLog(id: UUID(), type: .wet,   loggedAt: Date(timeIntervalSince1970: 1_000))
        let newer = DiaperLog(id: UUID(), type: .dirty, loggedAt: Date(timeIntervalSince1970: 2_000))
        // Act
        try await repo.save(older)
        try await repo.save(newer)
        let all = try await repo.all()
        // Assert
        XCTAssertEqual(all.first?.id, newer.id, "newest entry must be first")
        XCTAssertEqual(all.last?.id,  older.id, "oldest entry must be last")
    }

    // MARK: - DiaperLogAnalytics.groupByDay — table-driven

    func test_groupByDay_tableDriven_groupCounts() {
        let cal    = Self.utcCalendar
        let clock1 = FixedClock(date: Date(timeIntervalSince1970: 86_400))   // 1970-01-02 00:00 UTC
        let clock2 = FixedClock(date: Date(timeIntervalSince1970: 172_800))  // 1970-01-03 00:00 UTC

        let d1a = DiaperLog(id: UUID(), type: .wet,   loggedAt: clock1.now())
        let d1b = DiaperLog(id: UUID(), type: .dirty, loggedAt: clock1.now() + 3_600) // +1 h, same day
        let d2  = DiaperLog(id: UUID(), type: .both,  loggedAt: clock2.now())

        struct Case {
            let description: String
            let input: [DiaperLog]
            let expectedGroups: Int
        }

        let cases: [Case] = [
            Case(description: "empty input → no groups",          input: [],             expectedGroups: 0),
            Case(description: "single entry → one group",         input: [d1a],          expectedGroups: 1),
            Case(description: "two same-day entries → one group", input: [d1a, d1b],     expectedGroups: 1),
            Case(description: "cross-day entries → two groups",   input: [d1a, d2],      expectedGroups: 2),
            Case(description: "all three → two groups",           input: [d1a, d1b, d2], expectedGroups: 2),
        ]

        for tc in cases {
            let groups = DiaperLogAnalytics.groupByDay(tc.input, calendar: cal)
            XCTAssertEqual(groups.count, tc.expectedGroups, tc.description)
        }
    }

    func test_groupByDay_newestGroupIsFirst() {
        // Arrange
        let cal     = Self.utcCalendar
        let dayOld  = Date(timeIntervalSince1970: 86_400)   // 1970-01-02
        let dayNew  = Date(timeIntervalSince1970: 172_800)  // 1970-01-03
        let logOld  = DiaperLog(id: UUID(), type: .wet,   loggedAt: dayOld)
        let logNew  = DiaperLog(id: UUID(), type: .dirty, loggedAt: dayNew)
        // Act
        let groups  = DiaperLogAnalytics.groupByDay([logOld, logNew], calendar: cal)
        // Assert
        XCTAssertEqual(groups.count, 2)
        XCTAssertGreaterThan(groups[0].0, groups[1].0, "newest day must be the first group")
    }

    func test_groupByDay_withinGroup_newestEntryFirst() {
        // Arrange
        let cal     = Self.utcCalendar
        let base    = Date(timeIntervalSince1970: 86_400)
        let earlier = DiaperLog(id: UUID(), type: .wet,   loggedAt: base)
        let later   = DiaperLog(id: UUID(), type: .dirty, loggedAt: base + 7_200) // +2 h
        // Act
        let groups  = DiaperLogAnalytics.groupByDay([earlier, later], calendar: cal)
        // Assert
        XCTAssertEqual(groups.count, 1)
        let entries = groups[0].1
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.id, later.id, "newest entry within the group must be first")
    }
}

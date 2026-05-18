import XCTest
@testable import LittleECore

final class GrowthAnalyticsTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func day(_ offset: Double) -> Date {
        now.addingTimeInterval(offset * 86_400)
    }

    private func entry(
        date: Date,
        weightGrams: Int? = nil,
        heightCm: Double? = nil,
        headCircumferenceCm: Double? = nil
    ) throws -> GrowthMeasurement {
        try GrowthMeasurement(
            date: date,
            weightGrams: weightGrams,
            heightCm: heightCm,
            headCircumferenceCm: headCircumferenceCm
        )
    }

    // MARK: - Empty

    func test_summary_empty_returnsAllNil() {
        let summary = GrowthAnalytics.summary([], now: now)

        XCTAssertNil(summary.latestWeightGrams)
        XCTAssertNil(summary.latestHeightCm)
        XCTAssertNil(summary.latestHeadCm)
        XCTAssertNil(summary.weightDeltaGramsLastWeek)
    }

    func test_summary_singleWeightEntry_returnsLatestAndNilDelta() throws {
        let e = try entry(date: day(-1), weightGrams: 8_200)

        let summary = GrowthAnalytics.summary([e], now: now)

        XCTAssertEqual(summary.latestWeightGrams, 8_200)
        XCTAssertNil(summary.weightDeltaGramsLastWeek)
    }

    func test_summary_twoWeightEntriesOneWeekApart_computesWeightDelta() throws {
        let old = try entry(date: day(-8), weightGrams: 8_080)
        let latest = try entry(date: day(-1), weightGrams: 8_200)

        let summary = GrowthAnalytics.summary([old, latest], now: now)

        XCTAssertEqual(summary.latestWeightGrams, 8_200)
        XCTAssertEqual(summary.weightDeltaGramsLastWeek, 120)
    }

    func test_summary_twoWeightEntriesSameDay_returnsNilDelta() throws {
        let a = try entry(date: day(-1), weightGrams: 8_200)
        let b = try entry(date: day(-1).addingTimeInterval(3_600), weightGrams: 8_150)

        let summary = GrowthAnalytics.summary([a, b], now: now)

        XCTAssertNil(summary.weightDeltaGramsLastWeek)
    }

    func test_summary_ignoresEntriesBeyondLookbackForDelta() throws {
        let stale = try entry(date: day(-35), weightGrams: 7_500)
        let latest = try entry(date: day(-1), weightGrams: 8_200)

        let summary = GrowthAnalytics.summary([stale, latest], now: now)

        XCTAssertNil(summary.weightDeltaGramsLastWeek)
    }

    func test_summary_latestHeightIndependentOfLatestWeight() throws {
        let weightOnly = try entry(date: day(-3), weightGrams: 8_100)
        let heightOnly = try entry(date: day(-1), heightCm: 68.5)

        let summary = GrowthAnalytics.summary([weightOnly, heightOnly], now: now)

        XCTAssertEqual(summary.latestWeightGrams, 8_100)
        XCTAssertEqual(summary.latestHeightCm, 68.5)
    }

    func test_summary_weightDeltaUsesGrams() throws {
        let prior = try entry(date: day(-9), weightGrams: 8_080)
        let latest = try entry(date: day(-1), weightGrams: 8_200)

        let summary = GrowthAnalytics.summary([prior, latest], now: now)

        XCTAssertEqual(summary.weightDeltaGramsLastWeek, 120)
    }
}

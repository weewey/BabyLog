import XCTest
@testable import BabyLogCore
import Foundation

final class PumpingScheduleTemplateTests: XCTestCase {

    // MARK: - Medela template shape

    func test_medelaTemplate_hasExpectedMetadata() {
        let t = PumpingScheduleTemplate.medelaEightSessionNewborn

        XCTAssertEqual(t.name, "Medela · 8 sessions · newborn")
        XCTAssertEqual(t.pumpBrand, "Medela")
        XCTAssertEqual(t.targetSessionsPerDay, 8)
        XCTAssertEqual(t.averageDurationMinutes, 20)
    }

    func test_medelaTemplate_hasEightSlotsInOrder() {
        let t = PumpingScheduleTemplate.medelaEightSessionNewborn

        XCTAssertEqual(t.slots.count, 8)
        XCTAssertEqual(t.slots.map(\.id), [
            "night",
            "morning-rise",
            "midday",
            "afternoon",
            "early-evening",
            "evening",
            "late-evening",
            "pre-sleep",
        ])
    }

    // MARK: - Night classification

    func test_medelaTemplate_nightSessionIsNight() {
        let slots = PumpingScheduleTemplate.medelaEightSessionNewborn.slots
        let night = slots.first { $0.id == "night" }

        XCTAssertEqual(night?.isNight, true)
    }

    func test_medelaTemplate_preSleepIsNight() {
        let slots = PumpingScheduleTemplate.medelaEightSessionNewborn.slots
        let preSleep = slots.first { $0.id == "pre-sleep" }

        XCTAssertEqual(preSleep?.isNight, true)
    }

    func test_medelaTemplate_middaySlotIsNotNight() {
        let slots = PumpingScheduleTemplate.medelaEightSessionNewborn.slots
        let midday = slots.first { $0.id == "midday" }

        XCTAssertEqual(midday?.isNight, false)
    }

    func test_medelaTemplate_onlyNightAndPreSleepAreNight() {
        let slots = PumpingScheduleTemplate.medelaEightSessionNewborn.slots

        let nightIds = slots.filter { $0.isNight }.map(\.id)

        XCTAssertEqual(Set(nightIds), Set(["night", "pre-sleep"]))
    }

    // MARK: - Tip of day

    func test_tipOfDay_isDeterministicPerDay() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)

        let first = PumpingScheduleTemplate.tipOfDay(for: d)
        let second = PumpingScheduleTemplate.tipOfDay(for: d)

        XCTAssertEqual(first, second)
    }

    func test_tipsRotation_hasAtLeastFourTips() {
        XCTAssertGreaterThanOrEqual(PumpingScheduleTemplate.tipsRotation.count, 4)
    }

    func test_tipOfDay_variesAcrossTheYear() {
        // Sample 30 days and ensure we see more than one distinct tip.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var seen = Set<String>()
        for offset in 0..<30 {
            let d = base.addingTimeInterval(Double(offset) * 86_400)
            seen.insert(PumpingScheduleTemplate.tipOfDay(for: d))
        }

        XCTAssertGreaterThan(seen.count, 1)
    }
}

import Foundation

/// Pure analytics functions for growth-measurement data.
///
/// All functions are deterministic and side-effect free. `now` is threaded
/// through for forward compatibility (e.g., age-adjusted percentiles) even
/// when it is not yet used by a given computation.
public enum GrowthAnalytics {

    public struct Summary: Equatable, Sendable {
        public let latestWeightGrams: Int?
        public let latestHeightCm: Double?
        public let latestHeadCm: Double?
        /// Latest weight minus the most recent earlier weight measurement whose
        /// date is at least 7 days before the latest weight, within a 30-day
        /// lookback window. `nil` when no such pair exists.
        public let weightDeltaGramsLastWeek: Int?

        public init(
            latestWeightGrams: Int?,
            latestHeightCm: Double?,
            latestHeadCm: Double?,
            weightDeltaGramsLastWeek: Int?
        ) {
            self.latestWeightGrams = latestWeightGrams
            self.latestHeightCm = latestHeightCm
            self.latestHeadCm = latestHeadCm
            self.weightDeltaGramsLastWeek = weightDeltaGramsLastWeek
        }
    }

    public static func summary(
        _ entries: [GrowthMeasurement],
        now: Date,
        calendar: Calendar = .current
    ) -> Summary {
        _ = now
        _ = calendar

        let weights = entries
            .compactMap { e -> (date: Date, grams: Int)? in
                guard let g = e.weightGrams else { return nil }
                return (e.date, g)
            }
            .sorted { $0.date > $1.date }

        let heights = entries
            .compactMap { e -> (date: Date, cm: Double)? in
                guard let h = e.heightCm else { return nil }
                return (e.date, h)
            }
            .sorted { $0.date > $1.date }

        let heads = entries
            .compactMap { e -> (date: Date, cm: Double)? in
                guard let h = e.headCircumferenceCm else { return nil }
                return (e.date, h)
            }
            .sorted { $0.date > $1.date }

        let latestWeight = weights.first
        let delta = weightDelta(in: weights)

        return Summary(
            latestWeightGrams: latestWeight?.grams,
            latestHeightCm: heights.first?.cm,
            latestHeadCm: heads.first?.cm,
            weightDeltaGramsLastWeek: delta
        )
    }

    private static func weightDelta(
        in weights: [(date: Date, grams: Int)]
    ) -> Int? {
        guard let latest = weights.first, weights.count >= 2 else { return nil }

        let sevenDays: TimeInterval = 7 * 86_400
        let thirtyDays: TimeInterval = 30 * 86_400
        let windowEnd = latest.date.addingTimeInterval(-sevenDays)
        let windowStart = latest.date.addingTimeInterval(-thirtyDays)

        let prior = weights.dropFirst().first { entry in
            entry.date <= windowEnd && entry.date >= windowStart
        }
        guard let prior else { return nil }
        return latest.grams - prior.grams
    }
}

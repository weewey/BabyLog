import Foundation

// MARK: - Typed ID

public struct GrowthMeasurementID: Hashable, Sendable {
    public let value: UUID

    public init(_ value: UUID = UUID()) {
        self.value = value
    }
}

// MARK: - Error

public enum GrowthMeasurementError: Error, Equatable {
    case noMeasurementFieldProvided
    case weightOutOfRange(Int)
    case heightOutOfRange(Double)
    case headCircumferenceOutOfRange(Double)
}

// MARK: - Domain type

public struct GrowthMeasurement: Sendable, Hashable {
    public let id: GrowthMeasurementID
    public let date: Date
    public let weightGrams: Int?
    public let heightCm: Double?
    public let headCircumferenceCm: Double?
    public let notes: String?

    // Validation ranges
    public static let weightRange: ClosedRange<Int>    = 500...15_000
    public static let heightRange: ClosedRange<Double> = 20.0...120.0
    public static let headRange:   ClosedRange<Double> = 20.0...60.0

    /// Failable initialiser with typed throws.
    /// `date` is always supplied by the caller — this type never calls `Date()` internally.
    public init(
        id: GrowthMeasurementID = GrowthMeasurementID(),
        date: Date,
        weightGrams: Int? = nil,
        heightCm: Double? = nil,
        headCircumferenceCm: Double? = nil,
        notes: String? = nil
    ) throws(GrowthMeasurementError) {
        // At least one measurement field must carry data.
        guard weightGrams != nil || heightCm != nil || headCircumferenceCm != nil else {
            throw GrowthMeasurementError.noMeasurementFieldProvided
        }

        if let w = weightGrams, !Self.weightRange.contains(w) {
            throw GrowthMeasurementError.weightOutOfRange(w)
        }
        if let h = heightCm, !Self.heightRange.contains(h) {
            throw GrowthMeasurementError.heightOutOfRange(h)
        }
        if let hc = headCircumferenceCm, !Self.headRange.contains(hc) {
            throw GrowthMeasurementError.headCircumferenceOutOfRange(hc)
        }

        self.id                  = id
        self.date                = date
        self.weightGrams         = weightGrams
        self.heightCm            = heightCm
        self.headCircumferenceCm = headCircumferenceCm
        self.notes               = notes
    }
}

import Foundation
import SwiftData

@Model
final class GrowthMeasurementModel {

    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var weightGrams: Int? = nil
    var heightCm: Double? = nil
    var headCircumferenceCm: Double? = nil
    var notes: String? = nil

    init(
        id: UUID = UUID(),
        date: Date = .distantPast,
        weightGrams: Int? = nil,
        heightCm: Double? = nil,
        headCircumferenceCm: Double? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.date = date
        self.weightGrams = weightGrams
        self.heightCm = heightCm
        self.headCircumferenceCm = headCircumferenceCm
        self.notes = notes
    }
}

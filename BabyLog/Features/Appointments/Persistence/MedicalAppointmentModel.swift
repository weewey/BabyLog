import Foundation
import SwiftData

@Model
final class MedicalAppointmentModel {

    var id: UUID = UUID()
    var title: String = ""
    var scheduledAt: Date = Date.distantPast
    var location: String? = nil
    var notes: String? = nil

    init(
        id: UUID = UUID(),
        title: String = "",
        scheduledAt: Date = .distantPast,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.scheduledAt = scheduledAt
        self.location = location
        self.notes = notes
    }
}

import Foundation
import SwiftData

@Model
final class MilestoneModel {

    var id: UUID = UUID()
    var title: String = ""
    var achievedAt: Date = Date.distantPast
    var notes: String? = nil

    init(
        id: UUID = UUID(),
        title: String = "",
        achievedAt: Date = .distantPast,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.achievedAt = achievedAt
        self.notes = notes
    }
}

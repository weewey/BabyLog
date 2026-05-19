import Foundation
import SwiftData

@Model
final class ChildProfileModel {

    var name: String = ""
    var dateOfBirth: Date = Date.distantPast

    init(name: String = "", dateOfBirth: Date = .distantPast) {
        self.name = name
        self.dateOfBirth = dateOfBirth
    }
}

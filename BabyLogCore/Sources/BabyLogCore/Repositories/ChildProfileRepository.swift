import Foundation

public protocol ChildProfileRepository: Sendable {
    func load() async throws -> ChildProfile?
    func save(_ profile: ChildProfile) async throws
}

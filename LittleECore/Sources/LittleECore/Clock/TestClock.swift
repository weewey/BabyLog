import Foundation

public final class TestClock: Clock, @unchecked Sendable {
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
    }

    public func now() -> Date {
        current
    }

    public func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }

    public func set(to date: Date) {
        current = date
    }
}

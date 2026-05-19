import Foundation

public func groupFeedsByDay(
    _ feeds: [FeedLog],
    calendar: Calendar = .current
) -> [(Date, [FeedLog])] {
    var buckets: [Date: [FeedLog]] = [:]
    for feed in feeds {
        let day = calendar.startOfDay(for: feed.loggedAt)
        buckets[day, default: []].append(feed)
    }
    return buckets
        .map { day, entries in
            (day, entries.sorted { $0.loggedAt > $1.loggedAt })
        }
        .sorted { $0.0 > $1.0 }
}

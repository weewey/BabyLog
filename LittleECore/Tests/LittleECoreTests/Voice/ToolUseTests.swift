import XCTest
@testable import LittleECore

final class ToolUseTests: XCTestCase {

    func test_feedDraft_defaultsAllFieldsToNil() {
        let draft = FeedDraft()

        XCTAssertNil(draft.volumeMl)
        XCTAssertNil(draft.loggedAt)
        XCTAssertNil(draft.source)
        XCTAssertNil(draft.notes)
    }

    func test_parsedIntent_feed_isEquatableByDraftContents() {
        let a = ToolUse.feed(FeedDraft(volumeMl: 120, source: .bottle))
        let b = ToolUse.feed(FeedDraft(volumeMl: 120, source: .bottle))
        let c = ToolUse.feed(FeedDraft(volumeMl: 60, source: .bottle))

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_parsedIntent_unknown_carriesReason() {
        let intent = ToolUse.unknown(reason: "could not parse")

        if case .unknown(let reason) = intent {
            XCTAssertEqual(reason, "could not parse")
        } else {
            XCTFail("expected .unknown")
        }
    }
}


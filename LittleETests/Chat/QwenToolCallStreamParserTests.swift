import XCTest
import LittleECore
@testable import LittleE

/// Unit tests for the Qwen 2.5 native `<tool_call>` streaming parser.
///
/// The parser is pure text processing — no llama.cpp dependency — so
/// these tests run today, before the llama.cpp SPM dep is wired into
/// `LittleE.xcodeproj`. They are the TDD spec for the parser's
/// behavior under chunked, back-to-back, and malformed input.
final class QwenToolCallStreamParserTests: XCTestCase {

    // MARK: - Single call

    func test_feed_emitsSingleToolCall_fromOneChunk() {
        var parser = QwenToolCallStreamParser()

        let events = parser.feed(
            #"<tool_call>{"name": "createFeedLog", "arguments": {"volumeMl": 120}}</tool_call>"#
        )

        XCTAssertEqual(events.count, 1)
        guard case let .toolCall(name, args) = events[0] else {
            return XCTFail("expected .toolCall, got \(events[0])")
        }
        XCTAssertEqual(name, "createFeedLog")
        XCTAssertEqual(args["volumeMl"], .int(120))
    }

    func test_feed_stripsProseAroundToolCall() {
        var parser = QwenToolCallStreamParser()

        let events = parser.feed(
            #"Sure! <tool_call>{"name": "createDiaperLog", "arguments": {"kind": "wet"}}</tool_call> All done."#
        )
        let tailEvents = parser.finish()

        let combined = events + tailEvents
        XCTAssertEqual(combined.count, 3)
        XCTAssertEqual(combined[0], .text("Sure! "))
        guard case let .toolCall(name, args) = combined[1] else {
            return XCTFail("expected .toolCall, got \(combined[1])")
        }
        XCTAssertEqual(name, "createDiaperLog")
        XCTAssertEqual(args["kind"], .string("wet"))
        XCTAssertEqual(combined[2], .text(" All done."))
    }

    // MARK: - Parallel calls

    func test_feed_emitsBackToBackParallelCalls() {
        var parser = QwenToolCallStreamParser()

        let chunk = #"<tool_call>{"name": "a", "arguments": {"x": 1}}</tool_call><tool_call>{"name": "b", "arguments": {"y": 2}}</tool_call>"#
        let events = parser.feed(chunk)

        XCTAssertEqual(events.count, 2)
        if case let .toolCall(n1, a1) = events[0] {
            XCTAssertEqual(n1, "a")
            XCTAssertEqual(a1["x"], .int(1))
        } else {
            XCTFail("expected .toolCall, got \(events[0])")
        }
        if case let .toolCall(n2, a2) = events[1] {
            XCTAssertEqual(n2, "b")
            XCTAssertEqual(a2["y"], .int(2))
        } else {
            XCTFail("expected .toolCall, got \(events[1])")
        }
    }

    // MARK: - Partial-chunk buffering

    func test_feed_buffersAcrossChunks_whenOpenTagIsSplit() {
        var parser = QwenToolCallStreamParser()

        // Chunk 1 ends in the middle of "<tool_call>" — parser must
        // hold the "<too" back instead of emitting it as prose.
        let part1 = parser.feed("hello <too")
        XCTAssertEqual(part1, [.text("hello ")])

        let part2 = parser.feed(
            #"l_call>{"name": "createFeedLog", "arguments": {"volumeMl": 60}}</tool_call>"#
        )
        XCTAssertEqual(part2.count, 1)
        guard case let .toolCall(name, args) = part2[0] else {
            return XCTFail("expected .toolCall, got \(part2[0])")
        }
        XCTAssertEqual(name, "createFeedLog")
        XCTAssertEqual(args["volumeMl"], .int(60))
    }

    func test_feed_buffersAcrossChunks_whenInnerJSONIsSplit() {
        var parser = QwenToolCallStreamParser()

        _ = parser.feed(#"<tool_call>{"name": "createFeedLog", "#)
        _ = parser.feed(#""arguments": {"volumeMl": "#)
        let finalEvents = parser.feed("90}}</tool_call>")

        XCTAssertEqual(finalEvents.count, 1)
        guard case let .toolCall(name, args) = finalEvents[0] else {
            return XCTFail("expected .toolCall, got \(finalEvents[0])")
        }
        XCTAssertEqual(name, "createFeedLog")
        XCTAssertEqual(args["volumeMl"], .int(90))
    }

    func test_feed_holdsBackLonePrefix_untilConfirmedNotATag() {
        var parser = QwenToolCallStreamParser()

        // A lone "<" at end of chunk must be buffered — it could be the
        // start of "<tool_call>". When the next chunk reveals it's just
        // "<b" (not a tag), the held bytes flush as plain text.
        let first = parser.feed("price is <")
        XCTAssertEqual(first, [.text("price is ")])

        let second = parser.feed("b 10 dollars")
        XCTAssertEqual(second, [.text("<b 10 dollars")])
    }

    // MARK: - Malformed recovery

    func test_feed_recoversFromMalformedJSON_asMalformedCallEvent() {
        var parser = QwenToolCallStreamParser()

        let events = parser.feed("<tool_call>not-json-at-all</tool_call>")

        XCTAssertEqual(events.count, 1)
        guard case let .malformedCall(raw) = events[0] else {
            return XCTFail("expected .malformedCall, got \(events[0])")
        }
        XCTAssertEqual(raw, "not-json-at-all")
    }

    func test_feed_recoversAfterMalformedCall_andKeepsStreaming() {
        var parser = QwenToolCallStreamParser()

        let events = parser.feed(
            #"<tool_call>garbage</tool_call><tool_call>{"name": "ok", "arguments": {}}</tool_call>"#
        )

        XCTAssertEqual(events.count, 2)
        if case .malformedCall = events[0] {} else {
            XCTFail("expected .malformedCall, got \(events[0])")
        }
        if case let .toolCall(name, _) = events[1] {
            XCTAssertEqual(name, "ok")
        } else {
            XCTFail("expected .toolCall, got \(events[1])")
        }
    }

    // MARK: - Finish

    func test_finish_emitsUnclosedEnvelope_asMalformedCall() {
        var parser = QwenToolCallStreamParser()

        _ = parser.feed(#"<tool_call>{"name": "createFeedLog""#)
        let finalEvents = parser.finish()

        XCTAssertEqual(finalEvents.count, 1)
        if case let .malformedCall(raw) = finalEvents[0] {
            XCTAssertEqual(raw, #"{"name": "createFeedLog""#)
        } else {
            XCTFail("expected .malformedCall, got \(finalEvents[0])")
        }
    }

    func test_finish_flushesHeldBackPartialTagPrefix() {
        var parser = QwenToolCallStreamParser()

        // A trailing "<" looks like it might start "<tool_call>", so
        // `feed` holds it back. `finish` must flush it as plain text
        // since we now know the stream has ended without a real tag.
        let feedEvents = parser.feed("ok <")
        XCTAssertEqual(feedEvents, [.text("ok ")])

        let finalEvents = parser.finish()
        XCTAssertEqual(finalEvents, [.text("<")])
    }
}

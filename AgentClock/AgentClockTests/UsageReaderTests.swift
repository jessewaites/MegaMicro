import XCTest
@testable import AgentClock

final class UsageReaderTests: XCTestCase {

    // MARK: Claude — headers

    func testClaudeHeadersParseIntoUtilisation() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: 200, httpVersion: nil,
            headerFields: [
                "anthropic-ratelimit-unified-5h-utilization": "0.27",
                "anthropic-ratelimit-unified-7d-utilization": "0.21",
                "anthropic-ratelimit-unified-5h-reset": "1786375800",
            ])!
        let usage = ClaudeUsageReader.parse(headers: response)
        XCTAssertEqual(usage.session, 0.27)
        XCTAssertEqual(usage.week, 0.21)
        XCTAssertEqual(usage.sessionResetsAt, Date(timeIntervalSince1970: 1786375800))
    }

    func testMissingHeadersAreEmptyRatherThanZero() throws {
        // Zero would draw an empty bar, which reads as "plenty left" — the
        // opposite of "we don't know".
        let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                       httpVersion: nil, headerFields: [:])!
        let usage = ClaudeUsageReader.parse(headers: response)
        XCTAssertNil(usage.session)
        XCTAssertNil(usage.week)
        XCTAssertTrue(usage.isEmpty)
    }

    // MARK: Codex — on-disk token_count

    private func payload(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testCodexWindowsSortByLengthNotByName() throws {
        // "primary" is whichever window the plan happens to lead with, so the
        // reader classifies by window_minutes instead of trusting the key.
        let object = try payload("""
        {"rate_limits":{"plan_type":"plus",
          "primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1786371278},
          "secondary":{"used_percent":40.0,"window_minutes":300,"resets_at":1786300000}}}
        """)
        let usage = CodexUsageReader.parse(object)
        XCTAssertEqual(usage.session, 0.40)   // the 5-hour window
        XCTAssertEqual(usage.week, 0.09)      // the 7-day window
        XCTAssertEqual(usage.planName, "plus")
    }

    func testCodexHandlesAWeeklyOnlyPlan() throws {
        let object = try payload("""
        {"rate_limits":{"plan_type":"plus",
          "primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1786371278},
          "secondary":null}}
        """)
        let usage = CodexUsageReader.parse(object)
        XCTAssertNil(usage.session)
        XCTAssertEqual(usage.week, 0.09)
    }

    /// The bug this pins down: `total_token_usage` is the session's lifetime
    /// spend, not what's in the context. Using it produced 461% on a real file.
    func testCodexContextUsesTheCurrentTurnNotLifetimeSpend() throws {
        let object = try payload("""
        {"info":{"model_context_window":258400,
                 "total_token_usage":{"input_tokens":1193514,"cached_input_tokens":0,
                                      "cache_write_input_tokens":0,"total_tokens":1193514},
                 "last_token_usage":{"input_tokens":16447,"cached_input_tokens":11008,
                                     "cache_write_input_tokens":0,"total_tokens":16565}}}
        """)
        let usage = CodexUsageReader.parse(object)
        let context = try XCTUnwrap(usage.context)
        XCTAssertEqual(context, Double(16447 + 11008) / 258400, accuracy: 0.0001)
        XCTAssertLessThan(context, 1.0, "context can never exceed the window")
    }

    func testCodexContextIsClampedNotUnbounded() throws {
        let object = try payload("""
        {"info":{"model_context_window":1000,
                 "last_token_usage":{"input_tokens":99999,"cached_input_tokens":0}}}
        """)
        XCTAssertEqual(CodexUsageReader.parse(object).context, 1.0)
    }

    func testMissingCodexSessionsReportsRatherThanCrashing() {
        let usage = CodexUsageReader.read(root: URL(fileURLWithPath: "/tmp/definitely-not-here"))
        XCTAssertNotNil(usage.error)
        XCTAssertTrue(usage.isEmpty)
    }
}

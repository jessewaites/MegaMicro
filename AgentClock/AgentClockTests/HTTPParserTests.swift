import XCTest
@testable import AgentClock

final class HTTPParserTests: XCTestCase {
    private func complete(_ result: HTTPRequestParser.Result) -> HTTPRequest? {
        if case .complete(let request) = result { return request }
        return nil
    }

    func testSimpleGET() {
        var parser = HTTPRequestParser()
        let request = complete(parser.append(Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/health")
        XCTAssertEqual(request?.body.count, 0)
    }

    func testPOSTWithBody() {
        var parser = HTTPRequestParser()
        let body = #"{"state":"waiting","source":"claude-code"}"#
        let raw = "POST /state HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = complete(parser.append(Data(raw.utf8)))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/state")
        let report = try? JSONDecoder().decode(StateReport.self, from: request?.body ?? Data())
        XCTAssertEqual(report?.state, "waiting")
        XCTAssertEqual(report?.source, "claude-code")
    }

    func testTornPackets() {
        var parser = HTTPRequestParser()
        let body = #"{"state":"error"}"#
        let raw = "POST /state HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = Data(raw.utf8)
        // Feed one byte at a time; only the final byte completes the request.
        for i in 0..<(data.count - 1) {
            let result = parser.append(data.subdata(in: i..<(i + 1)))
            if case .complete = result {
                XCTFail("completed early at byte \(i)")
            }
        }
        let request = complete(parser.append(data.subdata(in: (data.count - 1)..<data.count)))
        XCTAssertEqual(request?.path, "/state")
        XCTAssertEqual(String(data: request?.body ?? Data(), encoding: .utf8), body)
    }

    func testHeaderCaseInsensitivity() {
        var parser = HTTPRequestParser()
        let raw = "POST /state HTTP/1.1\r\ncOnTeNt-LeNgTh: 2\r\n\r\nhi"
        let request = complete(parser.append(Data(raw.utf8)))
        XCTAssertEqual(String(data: request?.body ?? Data(), encoding: .utf8), "hi")
    }

    func testOversizedBodyRejected() {
        var parser = HTTPRequestParser()
        let raw = "POST /state HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maxBodyBytes + 1)\r\n\r\n"
        if case .invalid = parser.append(Data(raw.utf8)) {} else {
            XCTFail("oversized body must be rejected")
        }
    }

    func testGarbageRequestLineRejected() {
        var parser = HTTPRequestParser()
        if case .invalid = parser.append(Data("nonsense\r\n\r\n".utf8)) {} else {
            XCTFail("bad request line must be rejected")
        }
    }

    func testStateReportRejectsOversizedOrControlCharacterMetadata() throws {
        let oversized = try JSONDecoder().decode(
            StateReport.self,
            from: Data(#"{"state":"coding","source":"\#(String(repeating: "x", count: 65))"}"#.utf8)
        )
        XCTAssertFalse(oversized.isReasonable)

        let controlCharacter = try JSONDecoder().decode(
            StateReport.self,
            from: Data(#"{"state":"coding","cwd":"bad\u0000path"}"#.utf8)
        )
        XCTAssertFalse(controlCharacter.isReasonable)

        let normal = try JSONDecoder().decode(
            StateReport.self,
            from: Data(#"{"state":"waiting","task":"Approve file access\nThen continue"}"#.utf8)
        )
        XCTAssertTrue(normal.isReasonable)
    }

    func testBrowserOriginsAllowTerminalClientsAndRejectForeignSites() {
        XCTAssertTrue(WebhookServer.isAllowedBrowserOrigin(nil), "curl has no Origin header")
        XCTAssertTrue(WebhookServer.isAllowedBrowserOrigin("http://localhost:3000"))
        XCTAssertTrue(WebhookServer.isAllowedBrowserOrigin("http://127.0.0.1:5173"))
        XCTAssertFalse(WebhookServer.isAllowedBrowserOrigin("https://example.com"))
        XCTAssertFalse(WebhookServer.isAllowedBrowserOrigin("not a URL"))
    }

    func testExternalMessageValidation() {
        XCTAssertTrue(ExternalMessageRequest(text: "TESTING", color: "#00FFFF",
                                             durationMs: 10_000).isReasonable)
        XCTAssertTrue(ExternalMessageRequest(text: "hello", color: "ff8800").isReasonable)
        XCTAssertFalse(ExternalMessageRequest(text: "", color: nil).isReasonable)
        XCTAssertFalse(ExternalMessageRequest(text: "hello", color: "orange").isReasonable)
        XCTAssertFalse(ExternalMessageRequest(text: "hello", durationMs: 200).isReasonable)
        XCTAssertFalse(ExternalMessageRequest(text: "bad\u{0}text").isReasonable)
    }
}

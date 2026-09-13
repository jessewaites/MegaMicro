import Foundation

/// The one JSON body the webhook accepts.
struct StateReport: Codable, Sendable {
    var source: String?
    var state: String
    var session: String?
    var cwd: String?
    /// Optional human-facing identity supplied by multi-agent tools. `source`
    /// remains the product/brand; these fields describe the worker itself.
    var agent: String?
    var parentSession: String?
    var model: String?
    var task: String?
    var terminalSession: String?
    var terminalKind: String?
    var terminalEndpoint: String?

    var isReasonable: Bool {
        field(source, max: 64) && field(session, max: 256) && field(cwd, max: 4096)
            && field(agent, max: 256) && field(parentSession, max: 256)
            && field(model, max: 256) && field(task, max: 2048, allowNewlines: true)
            && field(terminalSession, max: 512)
            && field(terminalKind, max: 64) && field(terminalEndpoint, max: 2048)
            && state.count <= 32
    }

    private func field(_ value: String?, max: Int, allowNewlines: Bool = false) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value.utf8.count <= max else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            if allowNewlines, scalar == "\n" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]   // keys lowercased
    var body: Data
}

/// Minimal incremental HTTP/1.1 request parser — just enough for a loopback
/// webhook (request line, headers, Content-Length body). Pure and testable;
/// no Network.framework here.
struct HTTPRequestParser {
    enum Result: Sendable {
        case needMore
        case complete(HTTPRequest)
        case invalid
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) -> Result {
        buffer.append(data)

        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeaderBytes ? .invalid : .needMore
        }

        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 3 else { return .invalid }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else { return .invalid }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        guard available >= contentLength else { return .needMore }

        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}

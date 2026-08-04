import Foundation
import Network

/// Localhost-only HTTP server receiving agent state reports:
///   POST /state  {"source":"claude-code","state":"waiting","session":"…","cwd":"…"}
///   GET  /health
/// Claude Code hooks (installed in M4) curl these from anywhere on the machine —
/// Conductor workspaces and Ghostty terminals alike.
final class WebhookServer: @unchecked Sendable {
    private let port: UInt16
    private let onState: @Sendable (StateReport) -> Void
    /// Optional provider for GET /sessions (debug/observability endpoint).
    var sessionsProvider: (@Sendable () async -> String)?
    /// Optional handler for POST /lightshow: starts the demo reel on the
    /// board and reports whether there was a board to start it on.
    var lightShowHandler: (@Sendable () async -> Bool)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "megamicro.webhook")
    private var activeConnections = 0
    private var recentRequests: [Date] = []
    private static let maximumConnections = 32
    private static let requestTimeout: TimeInterval = 5
    private static let maximumRequestsPerWindow = 120
    private static let rateWindow: TimeInterval = 10

    private(set) var isRunning = false

    init(port: UInt16, onState: @escaping @Sendable (StateReport) -> Void) {
        self.port = port
        self.onState = onState
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            guard self.activeConnections < Self.maximumConnections else {
                connection.cancel()
                return
            }
            self.activeConnections += 1
            self.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        var finished = false
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: break
            default: return
            }
            guard !finished else { return }
            finished = true
            self?.activeConnections = max(0, (self?.activeConnections ?? 1) - 1)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            connection.cancel()
        }
        receive(on: connection, parser: HTTPRequestParser())
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser) {
        var parser = parser
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                switch parser.append(data) {
                case .needMore:
                    self.receive(on: connection, parser: parser)
                case .invalid:
                    self.respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
                case .complete(let request):
                    self.route(request, on: connection)
                }
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, parser: parser)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        if !Self.isAllowedBrowserOrigin(request.headers["origin"]) {
            respond(connection, status: "403 Forbidden", json: #"{"ok":false,"error":"browser origin rejected"}"#)
            return
        }
        let now = Date()
        recentRequests.removeAll { now.timeIntervalSince($0) > Self.rateWindow }
        guard recentRequests.count < Self.maximumRequestsPerWindow else {
            respond(connection, status: "429 Too Many Requests", json: #"{"ok":false,"error":"rate limit"}"#)
            return
        }
        recentRequests.append(now)
        switch (request.method, request.path) {
        case ("GET", "/health"):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            respond(connection, status: "200 OK", json: #"{"ok":true,"version":"\#(version)"}"#)
        case ("GET", "/sessions"):
            if let provider = sessionsProvider {
                Task { [weak self] in
                    let json = await provider()
                    self?.respond(connection, status: "200 OK", json: json)
                }
            } else {
                respond(connection, status: "200 OK", json: "[]")
            }
        case ("POST", "/lightshow"):
            guard let handler = lightShowHandler else {
                respond(connection, status: "503 Service Unavailable", json: #"{"ok":false,"error":"no board"}"#)
                return
            }
            Task { [weak self] in
                let started = await handler()
                if started {
                    self?.respond(connection, status: "200 OK",
                                  json: #"{"ok":true,"seconds":\#(Int(LightShow.duration))}"#)
                } else {
                    self?.respond(connection, status: "409 Conflict",
                                  json: #"{"ok":false,"error":"keyboard not connected, or a light show is already running"}"#)
                }
            }
        case ("POST", "/state"):
            if let report = try? JSONDecoder().decode(StateReport.self, from: request.body),
               report.isReasonable {
                onState(report)
                respond(connection, status: "200 OK", json: #"{"ok":true}"#)
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false,"error":"bad body"}"#)
            }
        default:
            respond(connection, status: "404 Not Found", json: #"{"ok":false,"error":"not found"}"#)
        }
    }

    static func isAllowedBrowserOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func respond(_ connection: NWConnection, status: String, json: String) {
        let body = Data(json.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

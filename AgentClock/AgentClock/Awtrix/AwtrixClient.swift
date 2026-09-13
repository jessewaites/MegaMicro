import Foundation

/// The slice of the device API the publisher drives. Split out from the
/// concrete client so the reconcile logic — which is where the subtle bugs
/// live — can be tested without a clock or a network.
protocol AwtrixTransport: Sendable {
    func pushApp(name: String, payload: Data) async throws
    func deleteApp(name: String) async throws
    func setOrder(_ order: [String], disabled: [String]) async throws
    func notify(payload: Data) async throws
    func dismissNotification(named name: String) async throws
}

/// Thin client for the AWTRIX NG HTTP API v1.
///
/// Note this is **not** AWTRIX 3. NG is a from-scratch rewrite whose docs say
/// plainly that "nothing carries over and v3 integrations must be reworked":
/// there is no `/api/custom`, and pushed apps and notifications now share one
/// payload schema under `/api/v1/`.
///
/// Every call is best-effort with a short timeout. The clock is an output
/// device — if it is unplugged, on another VLAN, or mid-reboot, that must cost
/// AgentClock nothing more than a `false` return. Agent detection never waits
/// on this.
actor AwtrixClient: AwtrixTransport {
    struct Endpoint: Equatable, Sendable {
        var host: String
        var username: String = ""
        var password: String = ""

        var isConfigured: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    enum ClientError: LocalizedError, Equatable {
        case notConfigured
        case badURL(String)
        /// The device rejected the request. AWTRIX returns a structured
        /// `{"error":{"code","message","field"}}` which is worth surfacing
        /// verbatim — "out of range on field brightness" beats "HTTP 422".
        case http(status: Int, message: String)
        case transport(String)
        case payloadTooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No clock configured"
            case .badURL(let host): "'\(host)' is not a usable address"
            case .http(let status, let message):
                message.isEmpty ? "Clock returned HTTP \(status)" : "Clock: \(message)"
            case .transport(let detail): detail
            case .payloadTooLarge(let bytes): "Payload is \(bytes) bytes; the clock accepts 8192"
            }
        }
    }

    /// The device rejects anything larger with 413. Checked before sending so a
    /// runaway page never even reaches the wire.
    static let maximumPayloadBytes = 8192

    private var endpoint: Endpoint
    private let session: URLSession

    init(endpoint: Endpoint = Endpoint(host: ""), timeout: TimeInterval = 2.5) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func update(endpoint: Endpoint) { self.endpoint = endpoint }
    var currentEndpoint: Endpoint { endpoint }

    // MARK: Device

    struct DeviceInfo: Decodable, Sendable {
        var uid: String?
        var version: String?
        var matrix: Matrix?

        struct Matrix: Decodable, Sendable {
            var width: Int?
            var height: Int?
        }

        /// Panels are 32–128 wide and always 8 tall. Default to the TC001's
        /// 32×8 when the firmware doesn't report it.
        var pixelWidth: Int { matrix?.width ?? 32 }
        var pixelHeight: Int { matrix?.height ?? 8 }
    }

    @discardableResult
    func device() async throws -> DeviceInfo {
        let data = try await send(method: "GET", path: "/api/v1/device")
        // Firmware builds differ in what they report; an undecodable body still
        // proves the clock answered, which is all reachability needs.
        return (try? JSONDecoder().decode(DeviceInfo.self, from: data)) ?? DeviceInfo()
    }

    /// Reachability without throwing — for status dots and polling loops.
    func isReachable() async -> Bool {
        (try? await device()) != nil
    }

    // MARK: Pushed apps

    /// `PUT` on an existing name replaces it wholesale; there is no separate
    /// create. Pushed apps live in RAM and are lost on reboot, which is why the
    /// publisher re-pushes on a heartbeat.
    func pushApp(name: String, payload: Data) async throws {
        try await send(method: "PUT", path: "/api/v1/apps/pushed/\(escape(name))", body: payload)
    }

    func deleteApp(name: String) async throws {
        try await send(method: "DELETE", path: "/api/v1/apps/\(escape(name))")
    }

    /// Rotation order. Persists to flash, so this survives power cuts even
    /// though the apps themselves do not.
    func setOrder(_ order: [String], disabled: [String]) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["order": order, "disabled": disabled])
        try await send(method: "PUT", path: "/api/v1/apps/order", body: body)
    }

    struct AppSummary: Decodable, Sendable {
        var name: String?
    }

    func apps() async throws -> [String] {
        let data = try await send(method: "GET", path: "/api/v1/apps")
        if let list = try? JSONDecoder().decode([AppSummary].self, from: data) {
            return list.compactMap(\.name)
        }
        if let names = try? JSONDecoder().decode([String].self, from: data) { return names }
        return []
    }

    // MARK: Notifications

    func notify(payload: Data) async throws {
        try await send(method: "POST", path: "/api/v1/notifications", body: payload)
    }

    /// Retract a named notification wherever it sits in the queue. Returns 200
    /// even when nothing is showing, so this is safe to call speculatively —
    /// which is exactly how the publisher clears a "needs you" the moment its
    /// agent unblocks.
    func dismissNotification(named name: String) async throws {
        try await send(method: "DELETE", path: "/api/v1/notifications/\(escape(name))")
    }

    func dismissActiveNotification() async throws {
        try await send(method: "DELETE", path: "/api/v1/notifications/active")
    }

    // MARK: Files (icons)

    struct FileListing: Decodable, Sendable {
        var files: [Entry]?
        var usedBytes: Int?
        var totalBytes: Int?

        struct Entry: Decodable, Sendable {
            var name: String?
            var size: Int?
        }

        /// Icon IDs are filenames without their extension.
        var iconIDs: Set<String> {
            Set((files ?? []).compactMap { entry in
                guard let name = entry.name else { return nil }
                return (name as NSString).deletingPathExtension
            })
        }
    }

    func icons() async throws -> FileListing {
        let data = try await send(method: "GET", path: "/api/v1/files?dir=/ICONS")
        return (try? JSONDecoder().decode(FileListing.self, from: data)) ?? FileListing()
    }

    /// Multipart upload of one icon. `filename` carries the extension the
    /// firmware sniffs on (`.gif` or `.jpg`); the ID it becomes is the stem.
    func uploadIcon(filename: String, data: Data) async throws {
        let boundary = "agentclock.\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try await send(method: "POST", path: "/api/v1/files?dir=/ICONS", body: body,
                       contentType: "multipart/form-data; boundary=\(boundary)",
                       enforcePayloadLimit: false)
    }

    // MARK: Transport

    @discardableResult
    private func send(method: String, path: String, body: Data? = nil,
                      contentType: String = "application/json",
                      enforcePayloadLimit: Bool = true) async throws -> Data {
        guard endpoint.isConfigured else { throw ClientError.notConfigured }
        if enforcePayloadLimit, let body, body.count > Self.maximumPayloadBytes {
            throw ClientError.payloadTooLarge(bytes: body.count)
        }
        guard let url = URL(string: Self.baseURLString(for: endpoint.host) + path) else {
            throw ClientError.badURL(endpoint.host)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            // PUT and PATCH without this header are refused with 415.
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if !endpoint.username.isEmpty || !endpoint.password.isEmpty {
            let pair = Data("\(endpoint.username):\(endpoint.password)".utf8).base64EncodedString()
            request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: Self.errorMessage(in: data))
        }
        return data
    }

    /// Accepts "1.2.3.4", "clock.local", "clock.local:8080", or a full URL —
    /// people paste whatever the web UI showed them.
    static func baseURLString(for host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return "http://" + (trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    /// Pull the human-readable half out of AWTRIX's error envelope.
    static func errorMessage(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return "" }
        let message = error["message"] as? String ?? error["code"] as? String ?? ""
        if let field = error["field"] as? String, !field.isEmpty, !message.isEmpty {
            return "\(message) (\(field))"
        }
        return message
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

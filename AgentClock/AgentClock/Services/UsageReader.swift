import Foundation
import Security

/// How much of each provider's quota is gone, and how full the context is.
struct ProviderUsage: Equatable, Sendable {
    /// The short window — Claude's five hours. Codex often has none.
    var session: Double?
    /// The long window — a week on both.
    var week: Double?
    var sessionResetsAt: Date?
    var weekResetsAt: Date?
    /// Current context fullness of the busiest live session, 0...1.
    var context: Double?
    var planName: String?
    /// Why the last read failed, for Diagnostics. Never surfaced on the panel.
    var error: String?

    var isEmpty: Bool { session == nil && week == nil && context == nil }
}

/// Claude's quota, via the trick Clawdmeter uses: the numbers aren't in any
/// local file, but every API response carries them in its headers. So make the
/// smallest possible request — one token of Haiku — and read the headers off it.
///
/// The OAuth token comes from the Keychain item Claude Code itself writes.
/// macOS will prompt the first time AgentClock reads it; that prompt is
/// expected and is the user granting access to their own credential.
actor ClaudeUsageReader {
    static let keychainService = "Claude Code-credentials"

    private let session: URLSession
    private var cached: ProviderUsage?
    private var lastPoll = Date.distantPast
    /// The token, held after the first successful read.
    ///
    /// The Keychain item belongs to Claude Code, not to us, so macOS puts up a
    /// confirmation sheet the first time AgentClock asks for it. Reading it on
    /// every poll meant that sheet reappearing every sixty seconds — a modal
    /// dialog on a one-minute timer, which is unusable. Ask once per launch.
    private var token: String?
    /// Set when the Keychain read failed or was refused. Polling stops rather
    /// than asking again: someone who clicked Deny meant it.
    private var accessRefused = false

    /// One call a minute is plenty — a five-hour window doesn't move fast, and
    /// this is somebody's account we're spending requests on.
    var minimumInterval: TimeInterval = 60

    init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func read(now: Date = Date(), force: Bool = false) async -> ProviderUsage {
        if !force, let cached, now.timeIntervalSince(lastPoll) < minimumInterval {
            return cached
        }
        lastPoll = now

        if accessRefused {
            return cached ?? ProviderUsage(error: "Keychain access was declined")
        }
        if token == nil { token = Self.accessToken() }
        guard let token else {
            accessRefused = true
            let usage = ProviderUsage(
                error: "No Claude credential available — Keychain access was declined or the item is missing")
            cached = usage
            return usage
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Deliberately the cheapest call the API accepts: one token of the
        // smallest model. We want the headers, not the answer.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ])

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            var usage = Self.parse(headers: http)
            if http.statusCode == 401 {
                // The cached token has expired; drop it so a later attempt can
                // pick up a refreshed one.
                self.token = nil
                usage.error = "Claude credential expired — run any Claude Code command to refresh it"
            } else if usage.isEmpty {
                usage.error = "No rate-limit headers in the response (HTTP \(http.statusCode))"
            }
            cached = usage
            return usage
        } catch {
            let usage = ProviderUsage(error: error.localizedDescription)
            cached = usage
            return usage
        }
    }

    /// The headers are the whole point of the request.
    static func parse(headers response: HTTPURLResponse) -> ProviderUsage {
        func value(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)
        }
        func fraction(_ name: String) -> Double? {
            value(name).flatMap(Double.init)
        }
        func date(_ name: String) -> Date? {
            value(name).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        }
        return ProviderUsage(
            session: fraction("anthropic-ratelimit-unified-5h-utilization"),
            week: fraction("anthropic-ratelimit-unified-7d-utilization"),
            sessionResetsAt: date("anthropic-ratelimit-unified-5h-reset"),
            weekResetsAt: date("anthropic-ratelimit-unified-7d-reset"),
            context: nil, planName: nil, error: nil)
    }

    /// Let the user re-authorise after a refusal, without relaunching.
    func retryAccess() {
        accessRefused = false
        token = nil
        lastPoll = .distantPast
    }

    /// Read the OAuth access token out of Claude Code's own Keychain item.
    static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }
}

/// Codex needs no API call at all: the CLI writes its own quota into every
/// rollout file as a `token_count` event. Strictly easier than Claude, and free.
enum CodexUsageReader {
    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    /// Parse the newest `token_count` event from the most recently touched
    /// rollout. Cheap enough to run on a timer: it reads one file, backwards.
    /// How many recent rollouts to try before giving up. The newest file is
    /// often a session that has only just started and has not logged usage
    /// yet — reading just that one reported "no usage" while perfectly good
    /// numbers sat in the file beside it.
    static let filesToTry = 8

    static func read(root: URL = sessionsRoot, now: Date = Date()) -> ProviderUsage {
        let candidates = recentRollouts(in: root, limit: filesToTry)
        guard !candidates.isEmpty else {
            return ProviderUsage(error: "No Codex sessions found")
        }
        for file in candidates {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Walk backwards: the last token_count is the current one.
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard line.contains("token_count") else { continue }
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = root["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count" else { continue }
                return parse(payload)
            }
        }
        return ProviderUsage(error: "No usage recorded in the last \(candidates.count) Codex sessions")
    }

    static func parse(_ payload: [String: Any]) -> ProviderUsage {
        var usage = ProviderUsage()
        let limits = payload["rate_limits"] as? [String: Any]
        usage.planName = limits?["plan_type"] as? String

        // `primary` and `secondary` are whichever windows the plan has; sort
        // them by length rather than assuming which is which.
        var windows: [(minutes: Int, used: Double, resets: Date?)] = []
        for key in ["primary", "secondary"] {
            guard let window = limits?[key] as? [String: Any],
                  let used = window["used_percent"] as? Double else { continue }
            let minutes = window["window_minutes"] as? Int ?? 0
            let resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            windows.append((minutes, used / 100, resets))
        }
        windows.sort { $0.minutes < $1.minutes }
        // A window under a day is the "session"; anything longer is the week.
        if let short = windows.first(where: { $0.minutes < 1440 }) {
            usage.session = short.used
            usage.sessionResetsAt = short.resets
        }
        if let long = windows.last(where: { $0.minutes >= 1440 }) {
            usage.week = long.used
            usage.weekResetsAt = long.resets
        }

        // Context is the *current turn's* footprint. `total_token_usage` is the
        // session's lifetime spend and will happily read several hundred
        // percent of the window — it is not what fills the context.
        if let info = payload["info"] as? [String: Any],
           let window = info["model_context_window"] as? Int, window > 0,
           let last = info["last_token_usage"] as? [String: Any] {
            let used = (last["input_tokens"] as? Int ?? 0)
                + (last["cached_input_tokens"] as? Int ?? 0)
                + (last["cache_write_input_tokens"] as? Int ?? 0)
            usage.context = min(1, Double(used) / Double(window))
        }
        return usage
    }

    /// The most recently touched rollouts, newest first.
    private static func recentRollouts(in root: URL, limit: Int) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { continue }
            found.append((url, modified))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

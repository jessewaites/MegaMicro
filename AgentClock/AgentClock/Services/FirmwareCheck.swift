import Foundation

/// Works out whether there is a panel here and whether it is ready to drive.
///
/// A Ulanzi TC001 ships with Ulanzi's own firmware, which has no HTTP API at
/// all — so "AgentClock can't find anything" is the single most likely first
/// experience, and "not found" is a useless thing to tell someone. This
/// distinguishes the cases that actually need different actions: not flashed,
/// flashed with the wrong firmware, flashed but not on the network, or ready.
///
/// It deliberately stops at diagnosis. AgentClock does not flash anything —
/// see `FirmwareCheck.Verdict.notFlashed` for why.
struct FirmwareCheck {

    enum Verdict: Equatable {
        /// AWTRIX NG is answering. The version it reported, when it said.
        case ready(version: String?)
        /// Something is there, but it is AWTRIX 3, whose API is entirely
        /// different — v3 has no `/api/v1` at all.
        case wrongFirmware(detail: String)
        /// A board that looks like an ESP32 is plugged in over USB, but nothing
        /// on the network is answering. Almost certainly still on its stock
        /// firmware.
        case notFlashed(port: String)
        /// Nothing found anywhere.
        case notFound

        var isReady: Bool { if case .ready = self { return true }; return false }

        var summary: String {
            switch self {
            case .ready(let version):
                "AWTRIX NG is running" + (version.map { " (\($0))" } ?? "")
            case .wrongFirmware(let detail):
                detail
            case .notFlashed:
                "A board is plugged in over USB, but nothing on the network is running AWTRIX NG"
            case .notFound:
                "No panel found"
            }
        }

        var advice: String? {
            switch self {
            case .ready:
                nil
            case .wrongFirmware:
                "AgentClock needs AWTRIX NG. It is a from-scratch rewrite of AWTRIX 3 with a different API — v3's endpoints do not exist here, so a v3 device cannot be driven. Re-flash with NG."
            case .notFlashed:
                "The TC001 ships with Ulanzi's own firmware, which has no network API. Flash AWTRIX NG with the browser flasher — and take a copy of the stock firmware first, because flashing overwrites it."
            case .notFound:
                "If the panel is flashed and on Wi-Fi, it scrolls its IP address across the display when it boots — type that into the Host field. If it is new, it needs flashing first."
            }
        }
    }

    static let flasherURL = URL(string: "https://blueforcer.github.io/awtrix-ng/getting-started/flashing/")!

    /// WebSerial is Chromium-only, so Safari cannot run the flasher at all —
    /// worth saying before someone clicks the link and hits a dead end.
    static let browserNote = "The flasher needs Chrome, Edge or Opera — Safari has no WebSerial."

    // MARK: Probing

    /// Ask a host what it is. `nil` host means "we have no address to try".
    static func probe(host: String?, using session: URLSession = .shared) async -> Verdict {
        if let host, !host.trimmingCharacters(in: .whitespaces).isEmpty {
            let base = AwtrixClient.baseURLString(for: host)
            if let version = await ngVersion(at: base, using: session) {
                return .ready(version: version)
            }
            if await looksLikeAwtrix3(at: base, using: session) {
                return .wrongFirmware(
                    detail: "\(host) is running AWTRIX 3, not AWTRIX NG")
            }
        }
        if let port = attachedBoardPort() {
            return .notFlashed(port: port)
        }
        return .notFound
    }

    private static func ngVersion(at base: String, using session: URLSession) async -> String? {
        guard let url = URL(string: base + "/api/v1/device") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A 200 is the answer; the version is a bonus some builds omit.
        return (object?["version"] as? String) ?? ""
    }

    /// AWTRIX 3 answers `/api/stats` and knows nothing about `/api/v1`.
    private static func looksLikeAwtrix3(at base: String, using session: URLSession) async -> Bool {
        guard let url = URL(string: base + "/api/stats") else { return false }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: USB

    /// Serial ports that look like an ESP32 dev board. The TC001 uses a
    /// CH340-family bridge; CP210x covers most of the rest.
    static func attachedBoardPort() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let candidates = names.filter { name in
            guard name.hasPrefix("cu.") else { return false }
            let lower = name.lowercased()
            return lower.contains("usbserial") || lower.contains("wchusbserial")
                || lower.contains("slab_usbtouart") || lower.contains("usbmodem")
        }
        return candidates.sorted().first.map { "/dev/" + $0 }
    }
}

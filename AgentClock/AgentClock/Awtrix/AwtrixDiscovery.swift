import Foundation
import Network

/// Finds AWTRIX NG panels on the LAN.
///
/// The firmware advertises `_awtrixng._tcp` over Bonjour and also answers a
/// `FIND_AWTRIXNG` UDP broadcast on port 4210. Bonjour is the polite option and
/// the one macOS gates behind `NSBonjourServices` — without that key in the
/// Info.plist the browse silently returns nothing, which is indistinguishable
/// from "no clock on this network", so that key is not optional.
///
/// Discovery is a convenience, never a requirement: the host field in Settings
/// always works, and on networks with mDNS blocked it is the only thing that
/// does.
@MainActor
@Observable
final class AwtrixDiscovery {
    struct Found: Identifiable, Hashable, Sendable {
        /// Bonjour service name, e.g. "awtrixng-a1b2c3".
        let name: String
        /// Resolved "host:port" or "host" suitable for the client.
        let host: String
        var id: String { name }
    }

    private(set) var results: [Found] = []
    private(set) var isBrowsing = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_awtrixng._tcp", domain: nil),
            using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    private func handle(_ found: Set<NWBrowser.Result>) {
        var names: [String] = []
        for result in found {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            names.append(name)
            // `<name>.local` is the reliable address: mDNS hostnames survive the
            // DHCP lease changes that make a cached IP go stale.
            let host = "\(name).local"
            if !results.contains(where: { $0.name == name }) {
                results.append(Found(name: name, host: host))
                resolvePort(name: name, type: type, domain: domain)
            }
        }
        results.removeAll { !names.contains($0.name) }
        results.sort { $0.name < $1.name }
    }

    /// Most panels sit on port 80 and need no suffix, but `webPort` is
    /// configurable — resolve it so a moved clock still works.
    private func resolvePort(name: String, type: String, domain: String) {
        let connection = NWConnection(
            to: .service(name: name, type: type, domain: domain, interface: nil),
            using: .tcp)
        resolvers[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            let port = connection.currentPath?.remoteEndpoint.flatMap { endpoint -> UInt16? in
                guard case .hostPort(_, let port) = endpoint else { return nil }
                return port.rawValue
            }
            Task { @MainActor in
                guard let self else { return }
                if let port, port != 80, let index = self.results.firstIndex(where: { $0.name == name }) {
                    self.results[index] = Found(name: name, host: "\(name).local:\(port)")
                }
                self.resolvers[name]?.cancel()
                self.resolvers[name] = nil
            }
        }
        connection.start(queue: .main)
    }
}

import Foundation

/// Everything AgentClock remembers between launches, as one versioned Codable
/// document. Deliberately small: MegaMicro's config carried keyboard profiles,
/// layouts, key colours and 30 migrations, none of which mean anything here.
struct AppConfig: Codable {
    static let currentVersion = 1

    var version: Int = AppConfig.currentVersion

    // MARK: Agent detection

    /// Loopback port the hooks report to. 48812 keeps clear of MegaMicro's
    /// 48802 so the two apps coexist on one machine.
    var webhookPort: UInt16 = 48812
    var hooksInstalled: Bool = false
    /// Hook event → reported state, editable so a CLI renaming an event is a
    /// config tweak rather than an app update.
    var claudeHookEvents: [String: String] = HookEvents.claude
    var codexHookEvents: [String: String] = HookEvents.codex
    /// Folders whose agents are hidden from the clock entirely.
    var fleetExclusions: [String] = []

    /// Read Claude's quota from the API.
    ///
    /// Off unless asked for: it means reading the OAuth token out of Claude
    /// Code's Keychain item (macOS will prompt once) and making a one-token
    /// request a minute on the user's account. Codex needs none of this — it
    /// writes its own quota to disk — so the switch is Claude-specific.
    var claudeUsageEnabled: Bool = false

    // MARK: The clock

    /// Host or IP of the AWTRIX NG device, e.g. "awtrixng-a1b2c3.local".
    /// Empty means "not set up yet"; the publisher stays silent.
    var clockHost: String = ""
    /// Devices with `authEnabled` need HTTP Basic credentials.
    var clockUsername: String = ""
    var clockPassword: String = ""
    /// Discovery found this host; remembered so a DHCP change self-heals.
    var lastDiscoveredHost: String = ""

    // MARK: Display

    var display = DisplayConfig()

    // MARK: App

    /// "system", "light", or "dark".
    var appearance: String = "system"
    var onboardingComplete: Bool = false

    init() {}

    /// Decoded field by field, falling back to the default for anything absent
    /// or unreadable.
    ///
    /// Swift's synthesized `init(from:)` calls `decode` for every non-optional
    /// property, so one missing key throws and the whole document is lost —
    /// which would mean every release that adds a setting silently resets the
    /// user's clock address. Leniency here is what makes the "additive changes
    /// need no migration" claim below actually true.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        version = container.value(.version, defaults.version)
        webhookPort = container.value(.webhookPort, defaults.webhookPort)
        hooksInstalled = container.value(.hooksInstalled, defaults.hooksInstalled)
        claudeHookEvents = container.value(.claudeHookEvents, defaults.claudeHookEvents)
        codexHookEvents = container.value(.codexHookEvents, defaults.codexHookEvents)
        fleetExclusions = container.value(.fleetExclusions, defaults.fleetExclusions)
        claudeUsageEnabled = container.value(.claudeUsageEnabled, defaults.claudeUsageEnabled)
        clockHost = container.value(.clockHost, defaults.clockHost)
        clockUsername = container.value(.clockUsername, defaults.clockUsername)
        clockPassword = container.value(.clockPassword, defaults.clockPassword)
        lastDiscoveredHost = container.value(.lastDiscoveredHost, defaults.lastDiscoveredHost)
        display = container.value(.display, defaults.display)
        appearance = container.value(.appearance, defaults.appearance)
        onboardingComplete = container.value(.onboardingComplete, defaults.onboardingComplete)
    }
}

private extension KeyedDecodingContainer {
    /// Decode, or fall back — never throw. A single unreadable field must not
    /// cost the user every other setting.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// What the clock actually shows. Every page can be switched off — some people
/// want only the amber "needs you" interrupt and nothing in the rotation.
struct DisplayConfig: Codable, Equatable {
    /// What the focused agent's page says. The mark is animated either way;
    /// this is about the words next to it.
    enum AgentPageStyle: String, Codable, CaseIterable, Sendable {
        /// "MEGAMICRO 12m" — which work, how long.
        case label
        /// "THINKING…" — what it is doing right now.
        case state
        /// Both, as two pages in the rotation.
        case both

        var showsLabel: Bool { self == .label || self == .both }
        var showsState: Bool { self == .state || self == .both }
    }

    /// What to do when a label is wider than the panel.
    enum LongText: String, Codable, CaseIterable, Sendable {
        /// Trim it so the page stands still and can be read at a glance.
        case shorten
        /// Show all of it, moving. Complete, but you have to wait for it.
        case scroll
    }

    /// Shorten by default: a desk clock is a glance surface, and waiting for a
    /// name to scroll past costs more than the letters it saves.
    var longText: LongText = .shorten

    /// Which provider-page layout to draw. Defaults to the one that carries
    /// all three facts: mark, crew, quota.
    var providerStyle: ProviderPage.Style = .bossAndCrew

    var agentPageStyle: AgentPageStyle = .both
    var showAgentPage: Bool = true
    var showFleetPage: Bool = true
    var showProjectPages: Bool = true

    var notifyOnWaiting: Bool = true
    var notifyOnError: Bool = true
    var notifyOnSuccess: Bool = false

    /// A waiting notification stays on screen until the agent stops waiting.
    /// This is the whole point of the hardware, so it defaults on.
    var holdWaiting: Bool = true
    var holdError: Bool = false
    /// Light a dark panel for an interrupt. On for waiting, off for the rest —
    /// nobody wants the room lit at 2am because a task finished.
    var wakeOnWaiting: Bool = true

    /// Beeps, off by default: the TC001 buzzer is loud and this app is meant to
    /// live on a desk you are already sitting at.
    var soundsEnabled: Bool = false

    /// Cap on per-project pages. The device holds 50 pushed apps total and a
    /// rotation longer than this stops being glanceable anyway.
    var maxProjectPages: Int = 6

    /// How long each AgentClock page holds the panel, in ms. 0 = device default.
    var pageDurationMs: Int = 0

    /// Scroll rate, as a percentage of the device's base 21 px/s. 60 reads
    /// comfortably across a room; 100 is quick enough that a long branch name
    /// goes by before you've finished it.
    var scrollSpeed: Int = 60

    /// Re-push every page this often so a rebooted clock (pushed apps live in
    /// RAM) recovers without user action.
    var heartbeatSeconds: TimeInterval = 300

    /// Per-state colours, as hex. Seeded from MegaMicro's palette at full value
    /// since the panel owns its own brightness.
    var stateColors: [String: String] = StatePalette.defaults

    /// The quota gauge's three bands.
    var gaugeColors: [String: String] = StatePalette.gaugeDefaults

    init() {}

    /// Lenient for the same reason as `AppConfig` — this is the sub-document
    /// most likely to gain fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplayConfig()
        longText = container.value(.longText, defaults.longText)
        providerStyle = container.value(.providerStyle, defaults.providerStyle)
        agentPageStyle = container.value(.agentPageStyle, defaults.agentPageStyle)
        showAgentPage = container.value(.showAgentPage, defaults.showAgentPage)
        showFleetPage = container.value(.showFleetPage, defaults.showFleetPage)
        showProjectPages = container.value(.showProjectPages, defaults.showProjectPages)
        notifyOnWaiting = container.value(.notifyOnWaiting, defaults.notifyOnWaiting)
        notifyOnError = container.value(.notifyOnError, defaults.notifyOnError)
        notifyOnSuccess = container.value(.notifyOnSuccess, defaults.notifyOnSuccess)
        holdWaiting = container.value(.holdWaiting, defaults.holdWaiting)
        holdError = container.value(.holdError, defaults.holdError)
        wakeOnWaiting = container.value(.wakeOnWaiting, defaults.wakeOnWaiting)
        soundsEnabled = container.value(.soundsEnabled, defaults.soundsEnabled)
        maxProjectPages = container.value(.maxProjectPages, defaults.maxProjectPages)
        pageDurationMs = container.value(.pageDurationMs, defaults.pageDurationMs)
        scrollSpeed = container.value(.scrollSpeed, defaults.scrollSpeed)
        heartbeatSeconds = container.value(.heartbeatSeconds, defaults.heartbeatSeconds)
        // Merge rather than replace: a user who retuned one colour still gets
        // any new state's default instead of an empty entry.
        stateColors = defaults.stateColors
            .merging(container.value(.stateColors, [:] as [String: String])) { _, saved in saved }
        gaugeColors = defaults.gaugeColors
            .merging(container.value(.gaugeColors, [:] as [String: String])) { _, saved in saved }
    }
}

/// Loads and saves the config document. Writes are 0600 via `PrivateFileStore`
/// and go through a temp file, so a crash mid-save cannot truncate the config.
enum ConfigStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentClock/config.json")
    }

    static func load(from url: URL = defaultURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        guard var config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            // A config we cannot read is not worth crashing over, but it is
            // worth keeping: move it aside so the user can recover settings.
            try? PrivateFileStore.backup(url, to: url.appendingPathExtension("corrupt"))
            return AppConfig()
        }
        config = migrate(config)
        return config
    }

    static func save(_ config: AppConfig, to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try PrivateFileStore.write(try encoder.encode(config), to: url)
    }

    /// No migrations yet — v1 is the first shipped format. New fields decode to
    /// their defaults, so additive changes need nothing here.
    private static func migrate(_ config: AppConfig) -> AppConfig {
        var config = config
        config.version = AppConfig.currentVersion
        return config
    }
}

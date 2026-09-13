import Foundation

/// One row in the Integrations pane.
struct IntegrationStatus: Identifiable {
    let id: String
    let name: String
    /// The agent's own source string, for picking its brand mark.
    let source: String
    let detail: String
    let installed: Bool
}

extension AppModel {
    /// Every provider AgentClock knows how to hook, freshly constructed on each
    /// access so they read the current port. These are cheap value-ish objects;
    /// the expensive part (touching the filesystem) happens in `isInstalled()`.
    var providerIntegrations: [ProviderIntegration] {
        let port = config.webhookPort
        var installers: [ProviderIntegration] = [
            HooksInstaller(port: port),
            CodexHooksInstaller(port: port),
            AntigravityHooksInstaller(port: port),
            OpenCodeIntegration(port: port),
            CopilotIntegration(port: port),
            CursorIntegration(port: port),
            QwenIntegration(port: port),
        ]
        // Claude's event map is user-editable; the others use their defaults.
        if let claude = installers.first as? HooksInstaller {
            claude.eventStates = config.claudeHookEvents
        }
        if let codex = installers.dropFirst().first as? CodexHooksInstaller {
            codex.eventStates = config.codexHookEvents
        }
        // Only offer what's actually on the machine, plus anything already
        // installed — so a removed CLI's leftover hooks can still be cleaned up.
        installers = installers.filter { $0.isDetected || $0.isInstalled() }
        return installers
    }

    var integrations: [IntegrationStatus] {
        providerIntegrations.map { integration in
            let installed = integration.isInstalled()
            return IntegrationStatus(
                id: integration.id,
                name: integration.displayName,
                source: integration.id,
                detail: installed ? "Reporting to AgentClock" : "Detected, not reporting",
                installed: installed)
        }
    }

    /// Install or remove one provider's hooks. Throws so the pane can show the
    /// real reason — a malformed settings.json is the common one, and in that
    /// case the installer deliberately refuses rather than rewriting the file.
    func setIntegration(_ id: String, installed: Bool) throws {
        guard let integration = providerIntegrations.first(where: { $0.id == id }) else { return }
        if installed {
            // ensureInstalled() copies the bridge out of the app bundle into
            // Application Support, so hooks keep working if the app moves.
            try BridgeLocator.ensureInstalled()
            try integration.install()
        } else {
            try integration.uninstall()
        }
        config.hooksInstalled = providerIntegrations.contains { $0.isInstalled() }
        scheduleConfigSave()
        log("\(installed ? "installed" : "removed") hooks for \(integration.displayName)")
    }
}

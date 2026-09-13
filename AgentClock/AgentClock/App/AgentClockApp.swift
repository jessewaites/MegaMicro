import SwiftUI
import AppKit

/// AgentClock is a regular app (Dock icon, ⌘Tab) that also puts a menu-bar
/// extra up. MegaMicro learned the hard way that `.menuBarExtraStyle(.window)`
/// combined with an accessory-mode app produces windows that render but refuse
/// clicks; keeping a real app here avoids that entirely.
@main
struct AgentClockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("AgentClock", id: "settings") {
            SettingsWindow()
                .environment(model)
                .onAppear { model.applyAppearance() }
        }
        .defaultSize(width: 820, height: 560)

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            // Reflects the fleet at a glance without opening anything: the
            // symbol takes the highest-priority state's colour.
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single instance. Two copies would fight over port 48812 and the
        // second would silently fail to receive any agent events.
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.processIdentifier != mine
        }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the settings window leaves the menu bar extra running — the
        // app's actual job is watching agents, not showing a window.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared?.showSettingsWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clear our pages off the clock so a quit app doesn't leave stale
        // agent status glowing on a desk overnight.
        AppModel.shared?.clearClockOnQuit()
    }
}

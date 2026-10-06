// LoginItem.swift: "Open at Login" for copies installed from the download. A copy installed by build.sh --install starts Squelch from
// LaunchAgent io.forit.squelch (tools/install.sh), which also restarts it after a crash; while that agent is
// there the menu item is hidden, so the two never both start it. Otherwise the first launch from /Applications
// registers Squelch with SMAppService, and the menu item turns that on and off. Turning it off sticks.
import Foundation
import ServiceManagement

enum LoginItem {
    static var launchAgent: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.forit.squelch.plist").path)
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// For status.json: launchagent | on | off | needs approval | not found
    static var summary: String {
        if launchAgent { return "launchagent" }
        switch status {
        case .enabled: return "on"
        case .requiresApproval: return "needs approval"
        case .notFound: return "not found"
        default: return "off"
        }
    }

    static func setUpOnce() {
        guard !launchAgent, Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: "loginItemSetUp") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemSetUp")
        set(true)
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.i("open at login \(on ? "on" : "off")")
        } catch {
            Log.i("open at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
        // Turned off in System Settings > General > Login Items: only the user can turn it back on there.
        if on && status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

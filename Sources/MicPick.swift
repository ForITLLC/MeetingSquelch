// MicPick.swift: which microphone a call is really using, and how the menu bar names it.
// A call app picks its own microphone (Teams may record from a Jabra Speak 710) while the
// Mac's default input can be another one (a RØDE Wireless MICRO for dictation, say). So in a call the
// menu bar names the mic the call app's own processes record from, read from Core Audio's process
// objects (MicWatcher.inputs), and with no call it names the default input the shortcut acts on.
// Plain logic only, no Core Audio, so tests/mic-harness.swift checks it without a call.
import Foundation

// One process recording one input device right now.
struct MicUse: Equatable {
    let bundleID: String   // the recording process, often a helper: com.microsoft.teams2.modulehost
    let device: UInt32     // the input's AudioDeviceID
    let name: String       // that input's name, e.g. "Jabra Speak 710"
}

enum MicPick {
    // The bundle ID prefixes of the processes that belong to a call app. Call apps record in
    // helpers with their own IDs (Teams: com.microsoft.teams2.modulehost, Edge: com.microsoft.edgemac.helper),
    // so these are prefixes. Every call name not listed here is a browser call (Meet, Teams web, Zoom web, ...).
    static func owners(ofCall app: String) -> [String] {
        switch app {
        case "Zoom": return ["us.zoom."]
        case "Webex": return ["Cisco-Systems."]
        case "FaceTime": return ["com.apple.FaceTime", "com.apple.avconferenced"]
        case "Teams": return ["com.microsoft.teams"]
        case "Slack": return ["com.tinyspeck.slackmacgap"]
        case "Discord": return ["com.hnc.Discord"]
        default: return ["com.microsoft.edgemac", "com.google.Chrome"]
        }
    }

    // The inputs a call records from, each device once, in the order Core Audio listed them.
    // Empty when none of the call app's processes is recording (the menu bar then names no device).
    static func callInputs(_ app: String, _ uses: [MicUse]) -> [MicUse] {
        let owners = owners(ofCall: app)
        var seen = Set<UInt32>()
        return uses.filter { u in owners.contains { u.bundleID.hasPrefix($0) } && seen.insert(u.device).inserted }
    }

    // The words for a set of inputs: "Jabra Speak 710", or "Jabra Speak 710 + Wireless MICRO" when the
    // call records from two. nil for none.
    static func label(_ uses: [MicUse]) -> String? {
        var names: [String] = []
        for u in uses where !u.name.isEmpty && !names.contains(u.name) { names.append(u.name) }
        return names.isEmpty ? nil : names.joined(separator: " + ")
    }
}

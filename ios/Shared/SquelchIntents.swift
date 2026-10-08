// SquelchIntents.swift: the presses the iPhone can make without opening the app. Compiled into the app (Siri,
// Shortcuts, the Action button, Spotlight) and into the Controls extension (Control Center, the Lock Screen).
// Each one reaches the paired Mac through RemoteClient.pressOnce: the app's open link when the app is up,
// otherwise a fresh connection that presses once and closes. Mute, Unmute and Get Call Status first read the
// Mac's state through RemoteClient.stateOnce, the same two ways.
import AppIntents
import SquelchRemote
import UIKit

/// The Mac answered a press with ok == false.
struct SquelchPressFailed: Error, LocalizedError {
    let why: String
    var errorDescription: String? { "The Mac couldn't do that: \(why)." }
}

enum SquelchPress {
    /// One press, by the phone's name as the Mac lists it.
    @MainActor
    static func run(_ what: String) async throws -> RemoteMessage {
        let done = try await RemoteClient.pressOnce(what, phoneName: UIDevice.current.name)
        if done.ok == false { throw SquelchPressFailed(why: done.why ?? "no reason given") }
        return done
    }

    /// The Mac's state now, nil when it has none yet.
    @MainActor
    static func state() async throws -> RemoteMessage? {
        try await RemoteClient.stateOnce(phoneName: UIDevice.current.name)
    }

    static func where_(_ m: RemoteMessage) -> String {
        if let app = m.app { return " in \(app)" }
        return ""
    }

    /// What a mic press did, from its done.
    static func muteDialog(_ done: RemoteMessage) -> IntentDialog {
        switch done.muted {
        case true?: return "Muted\(where_(done))."
        case false?: return "Unmuted\(where_(done))."
        case nil: return "Pressed mute on the computer."
        }
    }

    static var unsure: IntentDialog { "Couldn't tell whether you're muted, so nothing was pressed." }
}

// The descriptions say "computer", never "Mac": App Store Connect drops a build whose intent text names an
// Apple product (ITMS-90626; build 3 was lost to it). Scripts/check_intent_metadata.py stops that in CI.

/// The phone's version of Control + Option + Command + M.
struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
    static let description = IntentDescription(
        "Mutes or unmutes you in the call on your paired computer, the same as Control + Option + Command + M there.")
    // Muting has to work from the Lock Screen without Face ID: that is the point of a remote.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await SquelchPress.run("mic")
        return .result(dialog: SquelchPress.muteDialog(done))
    }
}

/// Mutes only if you aren't already, so a shortcut can run it without knowing which way the mic is.
struct MuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute"
    static let description = IntentDescription(
        "Mutes you in the call on your paired computer. Does nothing if you're already muted.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // No state, or a mic with no mute switch: a blind press could just as well unmute.
        guard let now = try await SquelchPress.state(), let muted = now.muted else {
            return .result(dialog: SquelchPress.unsure)
        }
        if muted { return .result(dialog: "Already muted\(SquelchPress.where_(now)).") }
        let done = try await SquelchPress.run("mic")
        return .result(dialog: SquelchPress.muteDialog(done))
    }
}

/// Unmutes only if you're muted: the mirror of MuteIntent.
struct UnmuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute"
    static let description = IntentDescription(
        "Unmutes you in the call on your paired computer. Does nothing if you aren't muted.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let now = try await SquelchPress.state(), let muted = now.muted else {
            return .result(dialog: SquelchPress.unsure)
        }
        if !muted { return .result(dialog: "Already unmuted\(SquelchPress.where_(now)).") }
        let done = try await SquelchPress.run("mic")
        return .result(dialog: SquelchPress.muteDialog(done))
    }
}

/// Turns the call's camera on or off.
struct ToggleCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Camera"
    static let description = IntentDescription("Turns your camera on or off in the call on your paired computer.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await SquelchPress.run("camera")
        switch done.camera {
        case true?: return .result(dialog: "Camera on\(SquelchPress.where_(done)).")
        case false?: return .result(dialog: "Camera off\(SquelchPress.where_(done)).")
        case nil: return .result(dialog: "Pressed camera on the Mac.")
        }
    }
}

/// Leaves the call. Ending a call by accident is worse than an extra unlock, so this one asks for Face ID.
struct LeaveCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Leave Call"
    static let description = IntentDescription("Leaves the call on your paired computer.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await SquelchPress.run("leave")
        return .result(dialog: "Left the call\(SquelchPress.where_(done)).")
    }
}

/// Starts or stops sharing your screen. Sharing by accident is worse than an extra unlock, so this one asks for
/// Face ID too.
struct ToggleScreenShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Screen Share"
    static let description = IntentDescription("Starts or stops sharing your screen in the call on your paired computer.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await SquelchPress.run("share")
        switch done.share {
        case true?: return .result(dialog: "Sharing your screen\(SquelchPress.where_(done)).")
        case false?: return .result(dialog: "Stopped sharing\(SquelchPress.where_(done)).")
        case nil: return .result(dialog: "Pressed screen share.")
        }
    }
}

/// Brings the call's window to the front, for when it is buried under others.
struct ShowCallWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Call Window"
    static let description = IntentDescription("Brings the call's window to the front on your paired computer.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await SquelchPress.run("front")
        return .result(dialog: "Brought the call\(SquelchPress.where_(done)) to the front.")
    }
}

/// What Get Call Status returns, for a shortcut to branch on. What the Mac didn't report reads as false or empty;
/// mutedKnown says whether muted is real.
struct CallStatus: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call Status"

    @Property(title: "In Call") var inCall: Bool
    @Property(title: "App") var app: String
    @Property(title: "Muted") var muted: Bool
    @Property(title: "Mute Known") var mutedKnown: Bool
    @Property(title: "Camera On") var cameraOn: Bool
    @Property(title: "Sharing") var sharing: Bool
    @Property(title: "Mic") var mic: String

    var displayRepresentation: DisplayRepresentation {
        guard inCall else { return DisplayRepresentation(title: "No call") }
        let mute: LocalizedStringResource? = mutedKnown ? (muted ? "Muted" : "Unmuted") : nil
        return DisplayRepresentation(title: "\(app) call", subtitle: mute)
    }

    // The system makes one with init() when it passes the value between actions, then fills it in.
    init() {
        inCall = false
        app = ""
        muted = false
        mutedKnown = false
        cameraOn = false
        sharing = false
        mic = ""
    }

    init(_ m: RemoteMessage) {
        self.init()
        inCall = m.inCall
        app = m.app ?? ""
        muted = m.muted ?? false
        mutedKnown = m.muted != nil
        cameraOn = m.camera ?? false
        sharing = m.share ?? false
        mic = m.mic ?? ""
    }

    /// "Teams call: muted, camera off." or "No call.", leaving out what the Mac didn't report.
    static func summary(_ m: RemoteMessage) -> String {
        guard let app = m.app else { return "No call." }
        var parts: [String] = []
        if let muted = m.muted { parts.append(muted ? "muted" : "unmuted") }
        if let camera = m.camera { parts.append(camera ? "camera on" : "camera off") }
        if m.share == true { parts.append("sharing your screen") }
        return parts.isEmpty ? "\(app) call." : "\(app) call: \(parts.joined(separator: ", "))."
    }
}

/// Reads the call without pressing anything, so a shortcut can decide what to press.
struct GetCallStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Call Status"
    static let description = IntentDescription(
        "Tells whether you're in a call on your paired computer, in which app, and whether you're muted, on camera or sharing your screen.",
        resultValueName: "Call Status")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CallStatus> & ProvidesDialog {
        guard let now = try await SquelchPress.state() else {
            throw SquelchPressFailed(why: "the computer didn't report its state")
        }
        return .result(value: CallStatus(now), dialog: "\(CallStatus.summary(now))")
    }
}

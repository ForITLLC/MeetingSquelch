// SquelchIntents.swift: the presses the iPhone can make without opening the app. Compiled into the app (Siri,
// Shortcuts, the Action button, Spotlight) and into the Controls extension (Control Center, the Lock Screen).
// Each one reaches the paired Mac through RemoteClient.pressOnce: the app's open link when the app is up,
// otherwise a fresh connection that presses once and closes.
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

    static func where_(_ m: RemoteMessage) -> String {
        if let app = m.app { return " in \(app)" }
        return ""
    }
}

// The descriptions say "computer", never "Mac": App Store Connect drops a build whose intent text names an
// Apple product (ITMS-90626; build 3 was lost to it). Scripts/check_intent_metadata.py stops that in CI.

/// The phone's version of Control + Option + Shift + Command + M.
struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
    static let description = IntentDescription(
        "Mutes or unmutes you in the call on your paired computer, the same as Control + Option + Shift + Command + M there.")
    // Muting has to work from the Lock Screen without Face ID: that is the point of a remote.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await SquelchPress.run("mic")
        switch done.muted {
        case true?: return .result(dialog: "Muted\(SquelchPress.where_(done)).")
        case false?: return .result(dialog: "Unmuted\(SquelchPress.where_(done)).")
        case nil: return .result(dialog: "Pressed mute on the Mac.")
        }
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

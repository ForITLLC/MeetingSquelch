// Intents.swift: Squelch's actions for Shortcuts on the Mac. Shortcuts can run an intent and a web page can't,
// which is why camera, share, leave and front are intents and not squelch:// URLs (AppDelegate.swift, testURLs).
// Each runs in the running app and takes the same route as a paired iPhone's press (AppDelegate.remotePress).
// build.sh extracts their metadata into Contents/Resources/Metadata.appintents; without it Shortcuts lists none.
import AppIntents
import AppKit

/// Squelch answered with ok == false, or isn't the app delegate it expects.
struct SquelchFailed: Error, LocalizedError {
    let why: String
    var errorDescription: String? { "Squelch couldn't do that: \(why)." }
}

@MainActor
enum IntentPress {
    static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    static func run(_ what: String) async throws -> RemoteMessage {
        guard let app = app else { throw SquelchFailed(why: "Squelch isn't running") }
        let done = await withCheckedContinuation { k in app.remotePress(what, source: "shortcuts") { k.resume(returning: $0) } }
        if done.ok == false { throw SquelchFailed(why: done.why ?? "no reason given") }
        return done
    }

    static func inApp(_ m: RemoteMessage) -> String { m.app.map { " in \($0)" } ?? "" }

    static func mic(_ m: RemoteMessage) -> IntentDialog {
        switch m.muted {
        case true?: return "Muted\(inApp(m))."
        case false?: return "Unmuted\(inApp(m))."
        case nil: return "Pressed mute\(inApp(m))."
        }
    }

    /// Mute or Unmute: presses only when the menu bar's state says it is the other way. A run that presses nothing
    /// still gets a log line, or a shortcut's Mute leaves no trace that it reached Squelch.
    static func set(muted want: Bool) async throws -> IntentDialog {
        let name = want ? "Mute" : "Unmute"
        switch app?.shownMuted {
        case want?:
            Log.i("shortcuts: \(name): already \(want ? "muted" : "unmuted"), nothing pressed")
            return want ? "Already muted." : "Already unmuted."
        case nil:
            Log.i("shortcuts: \(name): mute state unknown (\(app?.shownCall ?? "no call")), nothing pressed")
            return "Couldn't tell whether you're muted, so nothing was pressed."
        default: return mic(try await run("mic"))
        }
    }
}

/// Control + Option + Command + M.
struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
    static let description = IntentDescription(
        "Mutes or unmutes you in the call, the same as Control + Option + Command + M. With no call, the default mic.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentPress.mic(try await IntentPress.run("mic")))
    }
}

struct MuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute"
    static let description = IntentDescription("Mutes you in the call. Does nothing when you are already muted.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await IntentPress.set(muted: true))
    }
}

struct UnmuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute"
    static let description = IntentDescription("Unmutes you in the call. Does nothing when you are already unmuted.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await IntentPress.set(muted: false))
    }
}

struct ToggleCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Camera"
    static let description = IntentDescription("Turns your camera on or off in the call.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await IntentPress.run("camera")
        switch done.camera {
        case true?: return .result(dialog: "Camera on.")
        case false?: return .result(dialog: "Camera off.")
        case nil: return .result(dialog: "Pressed camera.")
        }
    }
}

struct ToggleScreenShareIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Screen Share"
    static let description = IntentDescription("Starts or stops sharing your screen in the call.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = try await IntentPress.run("share")
        switch done.share {
        case true?: return .result(dialog: "Sharing your screen.")
        case false?: return .result(dialog: "Stopped sharing.")
        case nil: return .result(dialog: "Pressed screen share.")
        }
    }
}

struct LeaveCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Leave Call"
    static let description = IntentDescription("Leaves the call.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IntentPress.run("leave")
        return .result(dialog: "Left the call.")
    }
}

struct ShowCallWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Call Window"
    static let description = IntentDescription("Brings the call's window to the front.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IntentPress.run("front")
        return .result(dialog: "Brought the call to the front.")
    }
}

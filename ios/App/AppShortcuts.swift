// AppShortcuts.swift: the intents Siri, Spotlight and the Action button offer without anyone building a shortcut.
import AppIntents

struct SquelchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMuteIntent(),
            phrases: [
                "Mute with \(.applicationName)",
                "Toggle mute with \(.applicationName)",
                "\(.applicationName) mute",
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "mic.slash.fill"
        )
        AppShortcut(
            intent: ToggleCameraIntent(),
            phrases: [
                "Toggle camera with \(.applicationName)",
                "\(.applicationName) camera",
            ],
            shortTitle: "Toggle Camera",
            systemImageName: "video.slash.fill"
        )
        AppShortcut(
            intent: LeaveCallIntent(),
            phrases: [
                "Leave the call with \(.applicationName)",
                "\(.applicationName) leave",
            ],
            shortTitle: "Leave Call",
            systemImageName: "phone.down.fill"
        )
        AppShortcut(
            intent: MuteIntent(),
            phrases: [
                "Mute me with \(.applicationName)",
                "Make sure I'm muted with \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "mic.slash.circle.fill"
        )
        AppShortcut(
            intent: UnmuteIntent(),
            phrases: [
                "Unmute me with \(.applicationName)",
                "\(.applicationName) unmute",
            ],
            shortTitle: "Unmute",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: ToggleScreenShareIntent(),
            phrases: [
                "Toggle screen share with \(.applicationName)",
                "Share my screen with \(.applicationName)",
                "\(.applicationName) share screen",
            ],
            shortTitle: "Toggle Screen Share",
            systemImageName: "rectangle.inset.filled.and.person.filled"
        )
        AppShortcut(
            intent: ShowCallWindowIntent(),
            phrases: [
                "Show the call with \(.applicationName)",
                "Bring the call to the front with \(.applicationName)",
            ],
            shortTitle: "Show Call Window",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: GetCallStatusIntent(),
            phrases: [
                "Get the call status from \(.applicationName)",
                "Am I muted in \(.applicationName)",
                "\(.applicationName) call status",
            ],
            shortTitle: "Call Status",
            systemImageName: "info.circle.fill"
        )
    }
}

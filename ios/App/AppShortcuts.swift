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
    }
}

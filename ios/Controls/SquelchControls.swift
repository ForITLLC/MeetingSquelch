// SquelchControls.swift: Mute and Camera buttons for Control Center, the Lock Screen and the Action button.
// Each runs its intent from Shared/SquelchIntents.swift here in the extension: it reads the pairing from the
// shared keychain group, connects to the Mac, presses once and closes.
import SwiftUI
import WidgetKit

@main
struct SquelchControlsBundle: WidgetBundle {
    var body: some Widget {
        MuteControl()
        CameraControl()
    }
}

struct MuteControl: ControlWidget {
    static let kind = "io.forit.squelch.controls.mute"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleMuteIntent()) {
                Label("Mute", systemImage: "mic.slash.fill")
            }
        }
        .displayName("Squelch Mute")
        .description("Mutes or unmutes you in the call on your Mac.")
    }
}

struct CameraControl: ControlWidget {
    static let kind = "io.forit.squelch.controls.camera"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleCameraIntent()) {
                Label("Camera", systemImage: "video.slash.fill")
            }
        }
        .displayName("Squelch Camera")
        .description("Turns your camera on or off in the call on your Mac.")
    }
}

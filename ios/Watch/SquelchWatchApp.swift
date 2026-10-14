// SquelchWatchApp.swift: Squelch on Apple Watch. Mute the call on the Mac from the wrist: the button, or a double
// tap of the fingers. The Watch reaches the Mac through the paired iPhone (PhoneLink), so it needs no pairing
// of its own: once the iPhone remote is paired with the Mac, the Watch works.
import SwiftUI

@main
struct SquelchWatchApp: App {
    @StateObject private var phone = PhoneLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environmentObject(phone)
                .task { phone.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { phone.refresh() }
        }
    }
}

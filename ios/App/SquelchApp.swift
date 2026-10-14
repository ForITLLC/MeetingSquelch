// SquelchApp.swift: the iPhone remote for Squelch on the Mac. Pair once by scanning the code the Mac shows,
// then the big button mutes the call on the Mac. The link is up while the app is on screen; Control Center,
// the Lock Screen, Siri and the Action button use the App Intents in Shared/ instead, and the Apple Watch asks
// through WatchRelay. The ForIT icon on the first screen opens the ForIT panel: Settings, with the ForIT account,
// Send feedback (FeedbackAccount).
import SwiftUI
import SquelchRemote

@main
struct SquelchApp: App {
    @StateObject private var client = RemoteClient(phoneName: UIDevice.current.name)
    @StateObject private var account = FeedbackAccount()
    @Environment(\.scenePhase) private var scenePhase
    @State private var problem: String?

    init() {
        WatchRelay.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView(problem: $problem)
                .environmentObject(client)
                .environmentObject(account)
                // The Mac's code is a squelch-pair:// link, so the Camera app can open it here too.
                .onOpenURL { url in
                    if account.handle(url) { return }
                    guard url.scheme == Remote.pairScheme else { return }
                    pair(url)
                }
                .onAppear {
                    RemoteClient.live = client
                    #if DEBUG
                    // Simulator checks have no camera: SIMCTL_CHILD_SQUELCH_PAIR_URL=squelch-pair://… pairs at launch.
                    // SIMCTL_CHILD_SQUELCH_FORGET=1 drops the pairing an earlier run left, for the pairing screen's shot.
                    let env = ProcessInfo.processInfo.environment
                    if env["SQUELCH_FORGET"] == "1" { client.forget() }
                    if let s = env["SQUELCH_PAIR_URL"], let url = URL(string: s) {
                        pair(url)
                    }
                    if let screen = sampleScreen { showSample(screen) }
                    #endif
                }
                .squelchRoot(account)
        }
        #if os(visionOS)
        // The remote is one button and two under it: a window sized to them, not visionOS's wide default.
        .defaultSize(width: 560, height: 680)
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: client.start()
            case .background: client.stop()
            default: break
            }
        }
    }

    #if DEBUG
    /// The device matrix's screens (forit-app.json): the pairing screen, or the remote on a sample Mac with no
    /// call (home, and Settings over it) or in one (detail). Nothing is stored and nothing connects.
    private func showSample(_ screen: String) {
        let noCall = RemoteMessage(t: "state", muted: false, mic: "USB Microphone")
        let inCall = RemoteMessage(t: "state", app: "Zoom", muted: true, camera: true, share: false)
        switch screen {
        case "gate": client.showSample(mac: nil)
        case "detail": client.showSample(mac: "Studio Mac", state: inCall)
        default: client.showSample(mac: "Studio Mac", state: noCall)
        }
    }
    #endif

    private func pair(_ url: URL) {
        guard let p = RemotePairing(url: url) else {
            problem = "That isn't a Squelch pairing code. On the Mac, choose Pair iPhone in the Squelch menu."
            return
        }
        do {
            try client.pair(p)
        } catch {
            problem = "Couldn't save the pairing on this \(ThisDevice.noun) (\(error.localizedDescription))."
        }
    }
}

#if DEBUG
/// The device matrix's `-squelch-screen gate|home|detail|settings` (ios/forit-app.json), from the launch arguments.
let sampleScreen = UserDefaults.standard.string(forKey: "squelch-screen")
/// Simulator checks: SIMCTL_CHILD_SQUELCH_SETTINGS=1 opens Settings at launch, for its VS-1 shot (sim-smoke.sh), and
/// so does the matrix's settings screen.
let settingsAtLaunch = ProcessInfo.processInfo.environment["SQUELCH_SETTINGS"] == "1" || sampleScreen == "settings"
#else
let settingsAtLaunch = false
#endif

/// Unpaired: the pairing screen. Paired: the remote.
struct RootView: View {
    @EnvironmentObject private var client: RemoteClient
    @Binding var problem: String?

    var body: some View {
        Group {
            if client.pairing == nil {
                PairView(problem: $problem)
            } else {
                RemoteView(problem: $problem)
            }
        }
        .alert("Squelch", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }
}

/// A screen laid out to fit, its Spacers sharing the room, until the largest text sizes make it taller than the
/// screen; then it scrolls from the top. Squeezed instead, SwiftUI cuts the text short: the a2800fd iPhone screens at
/// the largest size showed "Pair with your…" and "Ca…" (VS-1).
struct FitOrScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content.frame(maxWidth: .infinity)
            }
        }
    }
}

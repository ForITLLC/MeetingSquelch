// SquelchApp.swift: the iPhone remote for Squelch on the Mac. Pair once by scanning the code the Mac shows,
// then the big button mutes the call on the Mac. The link is up while the app is on screen; Control Center,
// the Lock Screen, Siri and the Action button use the App Intents in Shared/ instead.
import SwiftUI
import SquelchRemote

@main
struct SquelchApp: App {
    @StateObject private var client = RemoteClient(phoneName: UIDevice.current.name)
    @Environment(\.scenePhase) private var scenePhase
    @State private var problem: String?

    var body: some Scene {
        WindowGroup {
            RootView(problem: $problem)
                .environmentObject(client)
                // The Mac's code is a squelch-pair:// link, so the Camera app can open it here too.
                .onOpenURL { url in
                    guard url.scheme == Remote.pairScheme else { return }
                    pair(url)
                }
                .onAppear {
                    RemoteClient.live = client
                    #if DEBUG
                    // Simulator checks have no camera: SIMCTL_CHILD_SQUELCH_PAIR_URL=squelch-pair://… pairs at launch.
                    if let s = ProcessInfo.processInfo.environment["SQUELCH_PAIR_URL"], let url = URL(string: s) {
                        pair(url)
                    }
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: client.start()
            case .background: client.stop()
            default: break
            }
        }
    }

    private func pair(_ url: URL) {
        guard let p = RemotePairing(url: url) else {
            problem = "That isn't a Squelch pairing code. On the Mac, choose Pair iPhone in the Squelch menu."
            return
        }
        do {
            try client.pair(p)
        } catch {
            problem = "Couldn't save the pairing on this iPhone (\(error.localizedDescription))."
        }
    }
}

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

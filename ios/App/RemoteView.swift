// RemoteView.swift: the remote. One big mute button, camera and leave under it, and the Mac's state above.
// In ForIT's build the ForIT icon leads the top bar and opens the ForIT panel: the account, Settings, Send feedback
// and ForIT apps (squelchProfileMenu, App/FeedbackAccount.swift). The … menu at the trailing end has what acts on the
// paired Mac: Pair again and Forget this Mac.
import SwiftUI
import SquelchRemote

struct RemoteView: View {
    @EnvironmentObject private var client: RemoteClient
    @Binding var problem: String?
    @State private var scanning = false
    @State private var settingsOpen = settingsAtLaunch
    @State private var confirmForget = false
    @State private var confirmLeave = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var connected: Bool { client.status == .connected }
    private var state: RemoteMessage? { client.state }
    private var muted: Bool? { state?.muted }
    private var inCall: Bool { state?.inCall ?? false }

    var body: some View {
        NavigationStack {
            FitOrScroll {
                VStack(spacing: 32) {
                    StatusLine(problem: $problem, scanning: $scanning)
                    Spacer()
                    muteButton
                    // Side by side, the largest text sizes cut the titles to "Ca…" and "Le…", so there they stack.
                    let row = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12))
                                                           : AnyLayout(HStackLayout(spacing: 20))
                    row {
                        SmallButton(title: state?.camera == true ? "Camera on" : "Camera",
                                    image: state?.camera == true ? "video.fill" : "video.slash.fill",
                                    busy: client.busy.contains("camera")) { press("camera") }
                            .disabled(!connected || !inCall)
                        // Leaving loses nothing, so it is a ForIT style and not red (ios-design.md, Palette rules 1, 2).
                        SmallButton(title: "Leave", image: "phone.down.fill",
                                    busy: client.busy.contains("leave")) { confirmLeave = true }
                            .disabled(!connected || !inCall)
                    }
                    Spacer()
                }
                .padding()
            }
            .squelchScreen()
            .navigationTitle(client.pairing?.name ?? "Squelch")
            .squelchInlineTitle()
            .squelchProfileMenu(isSettingsPresented: $settingsOpen)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            scanning = true
                        } label: {
                            Label("Pair again", systemImage: "qrcode.viewfinder")
                        }
                        Button(role: .destructive) {
                            confirmForget = true
                        } label: {
                            Label("Forget this Mac", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("More")
                    }
                    #if os(visionOS)
                    // visionOS fills a tinted toolbar menu with the tint, which made it look chosen beside the gray
                    // buttons (the 67799d2 screens). Untinted, it is one of the window's gray buttons.
                    .tint(nil as Color?)
                    #endif
                }
            }
            .confirmationDialog("Forget \(client.pairing?.name ?? "this Mac")?", isPresented: $confirmForget,
                                titleVisibility: .visible) {
                Button("Forget this Mac", role: .destructive) { client.forget() }
            } message: {
                Text("This \(ThisDevice.noun) stops controlling it. To remove it on the Mac too, use Paired iPhones in the Squelch menu there.")
            }
            .confirmationDialog("Leave the call\(state?.app.map { " in \($0)" } ?? "")?", isPresented: $confirmLeave,
                                titleVisibility: .visible) {
                Button("Leave") { press("leave") }
            }
            .sheet(isPresented: $scanning) {
                ScanSheet(problem: $problem)
            }
            .muteFeedback(muted)
        }
    }

    /// Live is the tint; Muted is red, as on the Mac's bar and in every call app; gray until the Mac answers.
    private var muteButton: some View {
        let on = muted == true
        let live = connected && !on
        let ink = live ? Color.onSquelchTint : .white
        return Button {
            press("mic")
        } label: {
            VStack(spacing: 10) {
                if client.busy.contains("mic") {
                    ProgressView().controlSize(.large).tint(ink)
                } else {
                    Image(systemName: on ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 72, weight: .semibold))
                }
                Text(muted == nil ? "Mute" : on ? "Muted" : "Live")
                    .font(.title2.bold())
            }
            .foregroundStyle(ink)
            .frame(width: 220, height: 220)
            .background(Circle().fill(live ? AnyShapeStyle(.tint) : AnyShapeStyle(on ? Color.red : Color.gray)))
        }
        .buttonStyle(.plain)
        .disabled(!connected)
        .accessibilityLabel(on ? "Unmute" : "Mute")
        .accessibilityHint(inCall ? "In \(state?.app ?? "the call")" : "No call. Mutes the Mac's microphone.")
    }

    private func press(_ what: String) {
        Task {
            do {
                let done = try await client.press(what)
                if done.ok == false { problem = SquelchPressFailed(why: done.why ?? "no reason given").errorDescription }
            } catch let e as RemoteClientError {
                problem = e.message
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Where the link is, and what the Mac is doing.
private struct StatusLine: View {
    @EnvironmentObject private var client: RemoteClient
    @Binding var problem: String?
    @Binding var scanning: Bool

    var body: some View {
        VStack(spacing: 8) {
            switch client.status {
            case .idle:
                Label("Not connected", systemImage: "wifi.slash").foregroundStyle(.secondary)
            case .searching:
                Label { Text("Looking for \(client.pairing?.name ?? "the Mac")") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            case .connecting:
                Label { Text("Connecting") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            case .connected:
                if let app = client.state?.app {
                    Label("In \(app)", systemImage: "phone.fill").foregroundStyle(.tint)
                } else {
                    Label("No call", systemImage: "phone").foregroundStyle(.secondary)
                    Text(noCallDetail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .failed(let e):
                Text(e.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if e.needsPairing {
                    Button("Scan a new code") { scanning = true }.buttonStyle(.bordered)
                } else {
                    Button("Try again") { client.reconnect() }.buttonStyle(.bordered)
                }
            }
        }
        .font(.headline)
        .frame(minHeight: 60)
    }

    private var noCallDetail: String {
        guard client.state?.muted != nil else { return "The Mac's microphone has no mute switch." }
        if let mic = client.state?.mic { return "The button mutes \(mic) on the Mac." }
        return "The button mutes the Mac's microphone."
    }
}

private struct SmallButton: View {
    let title: String
    let image: String
    let busy: Bool
    let action: () -> Void
    /// One height for every symbol, so the titles line up: video.slash is taller than phone.down.
    @ScaledMetric(relativeTo: .title2) private var symbolHeight: CGFloat = 30
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            // At the largest text sizes the symbol leads the title in a full-width button (RemoteView stacks them).
            if typeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    symbol
                    Text(title).font(Self.titleFont)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                VStack(spacing: 6) {
                    symbol
                    Text(title).font(Self.titleFont)
                }
                .frame(width: 100, height: 72)
            }
        }
        .squelchSecondaryButton()
    }

    private var symbol: some View {
        Group {
            if busy {
                ProgressView()
            } else {
                Image(systemName: image).font(.title2)
            }
        }
        .frame(height: symbolHeight)
    }

    /// Larger on Apple Vision Pro, where the window is farther away.
    private static var titleFont: Font {
        #if os(visionOS)
        .callout.bold()
        #else
        .footnote.bold()
        #endif
    }
}

private extension View {
    /// A heavy tap when the mute flips. visionOS has sensoryFeedback only from 26, and no haptics to give.
    @ViewBuilder func muteFeedback(_ muted: Bool?) -> some View {
        #if os(visionOS)
        self
        #else
        sensoryFeedback(.impact(weight: .heavy), trigger: muted)
        #endif
    }
}

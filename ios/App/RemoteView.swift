// RemoteView.swift: the remote. One big mute button, camera and leave under it, and the Mac's state above.
import SwiftUI
import SquelchRemote

struct RemoteView: View {
    @EnvironmentObject private var client: RemoteClient
    @Binding var problem: String?
    @State private var scanning = false
    @State private var confirmForget = false
    @State private var confirmLeave = false

    private var connected: Bool { client.status == .connected }
    private var state: RemoteMessage? { client.state }
    private var muted: Bool? { state?.muted }
    private var inCall: Bool { state?.inCall ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                StatusLine(problem: $problem, scanning: $scanning)
                Spacer()
                muteButton
                HStack(spacing: 20) {
                    SmallButton(title: state?.camera == true ? "Camera on" : "Camera",
                                image: state?.camera == true ? "video.fill" : "video.slash.fill",
                                busy: client.busy.contains("camera")) { press("camera") }
                        .disabled(!connected || !inCall)
                    SmallButton(title: "Leave", image: "phone.down.fill", tint: .red,
                                busy: client.busy.contains("leave")) { confirmLeave = true }
                        .disabled(!connected || !inCall)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(client.pairing?.name ?? "Squelch")
            .navigationBarTitleDisplayMode(.inline)
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
                }
            }
            .confirmationDialog("Forget \(client.pairing?.name ?? "this Mac")?", isPresented: $confirmForget,
                                titleVisibility: .visible) {
                Button("Forget this Mac", role: .destructive) { client.forget() }
            } message: {
                Text("This iPhone stops controlling it. To remove the iPhone on the Mac too, use Paired iPhones in the Squelch menu there.")
            }
            .confirmationDialog("Leave the call\(state?.app.map { " in \($0)" } ?? "")?", isPresented: $confirmLeave,
                                titleVisibility: .visible) {
                Button("Leave", role: .destructive) { press("leave") }
            }
            .sheet(isPresented: $scanning) {
                ScanSheet(problem: $problem)
            }
            .sensoryFeedback(.impact(weight: .heavy), trigger: muted)
        }
    }

    private var muteButton: some View {
        let on = muted == true
        return Button {
            press("mic")
        } label: {
            VStack(spacing: 10) {
                if client.busy.contains("mic") {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: on ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 72, weight: .semibold))
                }
                Text(muted == nil ? "Mute" : on ? "Muted" : "Live")
                    .font(.title2.bold())
            }
            .foregroundStyle(.white)
            .frame(width: 220, height: 220)
            .background(Circle().fill(!connected ? Color.gray : on ? Color.red : Color.accentColor))
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
                    Label("In \(app)", systemImage: "phone.fill").foregroundStyle(.green)
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
        if let mic = client.state?.mic { return "Mute works on the Mac's microphone, \(mic)." }
        return "Mute works on the Mac's microphone."
    }
}

private struct SmallButton: View {
    let title: String
    let image: String
    var tint: Color = .accentColor
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: image).font(.title2)
                }
                Text(title).font(.footnote.bold())
            }
            .frame(width: 100, height: 72)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}

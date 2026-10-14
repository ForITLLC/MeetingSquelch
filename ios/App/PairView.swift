// PairView.swift: the first screen. Scan the code the Mac shows under Pair iPhone in the Squelch menu.
import SwiftUI
import SquelchRemote

struct PairView: View {
    @EnvironmentObject private var client: RemoteClient
    @Binding var problem: String?
    @State private var scanning = false
    @State private var settingsOpen = settingsAtLaunch

    var body: some View {
        NavigationStack {
            FitOrScroll {
                VStack(spacing: 28) {
                    Spacer()
                    Image(systemName: "mic.slash.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.tint)
                    Text("Pair with your Mac")
                        .font(.title.bold())
                    VStack(alignment: .leading, spacing: 12) {
                        Step(n: 1, text: "On the Mac, open the Squelch menu in the menu bar and choose Pair iPhone.")
                        #if os(visionOS)
                        Step(n: 2, text: "Click Copy Link for Apple Vision Pro under the code. Or point your iPhone's Camera at the code, touch and hold the link, and choose Copy Link.")
                        Step(n: 3, text: "Paste it here. Keep the Mac and this Apple Vision Pro on the same Wi-Fi.")
                        #else
                        Step(n: 2, text: "Scan the code it shows. The Camera app works too.")
                        Step(n: 3, text: "Keep both on the same Wi-Fi.")
                        #endif
                    }
                    .padding(.horizontal)
                    Spacer()
                    #if os(visionOS)
                    PasteLink(found: pair)
                    #else
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .squelchPrimaryButton()
                    .disabled(!QRScanner.canScan)
                    if !QRScanner.canScan {
                        Text("This \(ThisDevice.noun) can't scan here. Use the Camera app on the code instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    #endif
                }
                .padding()
            }
            .squelchScreen()
            .navigationTitle("Squelch")
            .squelchInlineTitle()
            .squelchProfileMenu(isSettingsPresented: $settingsOpen)
        }
        .sheet(isPresented: $scanning) {
            ScanSheet(problem: $problem)
        }
    }

    #if os(visionOS)
    private func pair(_ url: URL) {
        guard let p = RemotePairing(url: url) else { return }
        do {
            try client.pair(p)
        } catch {
            problem = "Couldn't save the pairing on this \(ThisDevice.noun) (\(error.localizedDescription))."
        }
    }
    #endif
}

/// The scanner in a sheet, closed by the first Squelch code it sees. On Apple Vision Pro, the paste button.
struct ScanSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @Binding var problem: String?

    var body: some View {
        NavigationStack {
            taker
                .squelchScreen()
                .squelchInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var taker: some View {
        #if os(visionOS)
        VStack(spacing: 24) {
            Text("On the Mac, choose Pair iPhone in the Squelch menu and click Copy Link for Apple Vision Pro, or copy the code's link with your iPhone's Camera. Then paste it here.")
                .multilineTextAlignment(.center)
            PasteLink(found: take)
        }
        .padding()
        .navigationTitle("Paste the Mac's link")
        #else
        QRScanner(found: take)
            .ignoresSafeArea()
            .navigationTitle("Scan the Mac's code")
        #endif
    }

    private func take(_ url: URL) {
        dismiss()
        guard let p = RemotePairing(url: url) else { return }
        do {
            try client.pair(p)
        } catch {
            problem = "Couldn't save the pairing on this \(ThisDevice.noun) (\(error.localizedDescription))."
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String
    /// The circle grows with the number, so the largest text sizes keep the number inside it.
    @ScaledMetric(relativeTo: .headline) private var badge: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.headline.monospacedDigit())
                .frame(width: badge, height: badge)
                .background(Circle().fill(.tint.opacity(0.15)))
            Text(text)
        }
    }
}

// PairView.swift: the first screen. Scan the code the Mac shows under Pair iPhone in the Squelch menu.
import SwiftUI
import SquelchRemote

struct PairView: View {
    @EnvironmentObject private var client: RemoteClient
    @Binding var problem: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "mic.slash.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.tint)
                Text("Pair with your Mac")
                    .font(.title.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Step(n: 1, text: "On the Mac, open the Squelch menu in the menu bar and choose Pair iPhone.")
                    Step(n: 2, text: "Scan the code it shows. The iPhone Camera app works too.")
                    Step(n: 3, text: "Keep both on the same Wi-Fi.")
                }
                .padding(.horizontal)
                Spacer()
                Button {
                    scanning = true
                } label: {
                    Label("Scan the code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!QRScanner.canScan)
                if !QRScanner.canScan {
                    Text("This iPhone can't scan here. Use the Camera app on the code instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Squelch")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $scanning) {
            ScanSheet(problem: $problem)
        }
    }
}

/// The scanner in a sheet, closed by the first Squelch code it sees.
struct ScanSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @Binding var problem: String?

    var body: some View {
        NavigationStack {
            QRScanner { url in
                dismiss()
                guard let p = RemotePairing(url: url) else { return }
                do {
                    try client.pair(p)
                } catch {
                    problem = "Couldn't save the pairing on this iPhone (\(error.localizedDescription))."
                }
            }
            .ignoresSafeArea()
            .navigationTitle("Scan the Mac's code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.headline.monospacedDigit())
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
        }
    }
}

// PasteLink.swift: pairing on Apple Vision Pro, which gives apps no camera scanner. The Mac's Pair iPhone window
// copies its squelch-pair:// link (Copy Link for Apple Vision Pro), or the iPhone Camera app reads the code and
// copies it (touch and hold the link, then Copy Link), and Universal Clipboard brings it here to paste.
#if os(visionOS)
import SwiftUI
import SquelchRemote

struct PasteLink: View {
    let found: (URL) -> Void
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 12) {
            PasteButton(payloadType: String.self) { items in
                let url = items.lazy
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .first { RemotePairing(url: $0) != nil }
                DispatchQueue.main.async {
                    wrong = url == nil
                    if let url { found(url) }
                }
            }
            .labelStyle(.titleAndIcon)
            if wrong {
                Text("That isn't a Squelch pairing link. On the Mac, choose Pair iPhone in the Squelch menu and click Copy Link for Apple Vision Pro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
#endif

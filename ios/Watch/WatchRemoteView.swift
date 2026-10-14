// WatchRemoteView.swift: the Watch's one screen. The call on the Mac at the top, then the mute button, as on the
// phone: the tint when live, red when muted, gray until the phone has said how the Mac is. Double Tap presses it
// (Apple Watch Series 9, Ultra 2 and later). ForITCommon doesn't build for watchOS, so the tint is the asset's copy
// of ForIT's cyan on black (#8EDCEF), and the red is the phone's.
import SquelchWatchLink
import SwiftUI

struct WatchRemoteView: View {
    @EnvironmentObject private var phone: PhoneLink

    private var muted: Bool? { phone.answer?.muted }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    statusLine
                    muteButton
                    if let p = phone.problem {
                        Text(p)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") { phone.refresh() }
                    }
                }
            }
            .navigationTitle("Squelch")
        }
        // A tap on the wrist when the mute flips, not when the first state arrives.
        .sensoryFeedback(trigger: muted) { old, new in old != nil && new != nil ? .success : nil }
    }

    @ViewBuilder private var statusLine: some View {
        Group {
            if let a = phone.answer {
                Text(a.app.map { "In \($0)" } ?? "No call")
                    .foregroundStyle(a.app == nil ? Color.secondary : Color.accentColor)
            } else if phone.asking {
                Text("Asking your iPhone")
                    .foregroundStyle(.secondary)
            } else {
                Text(" ")
            }
        }
        .font(.footnote)
        .lineLimit(1)
    }

    private var muteButton: some View {
        let on = muted == true
        let live = muted == false
        return Button {
            phone.toggleMute()
        } label: {
            ZStack {
                Circle().fill(phone.answer == nil ? Color.gray : on ? Color.red : Color.accentColor)
                if phone.pressing {
                    ProgressView()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: on ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 34, weight: .semibold))
                        Text(muted == nil ? "Mute" : on ? "Muted" : "Live")
                            .font(.headline)
                    }
                    // Black on the light cyan, white on red and gray.
                    .foregroundStyle(live ? Color.black : Color.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 22)
        }
        .buttonStyle(.plain)
        .disabled(phone.pressing)
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel(on ? "Unmute" : "Mute")
        .accessibilityHint(phone.answer?.app.map { "In \($0) on your Mac" } ?? "Mutes your Mac's microphone")
    }
}

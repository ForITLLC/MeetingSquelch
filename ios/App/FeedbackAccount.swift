// FeedbackAccount.swift: Send feedback, Settings and the palette. ForIT's own build files feedback on ForIT's task
// board, which takes ForIT accounts only, and draws Settings and its colours with ForIT's shared chrome, through a
// package that is not public. This build has no Send feedback and no account: Settings has the version, every link
// the app opens is a pairing link, and the colours are the system's.
import SwiftUI

@MainActor
final class FeedbackAccount: ObservableObject {
    /// The sign-in redirect in ForIT's build; this one has no sign-in.
    func handle(_ url: URL) -> Bool { false }
}

/// Settings: the version.
private struct SettingsSheet: ViewModifier {
    let isPresented: Binding<Bool>

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isPresented.wrappedValue = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
            .sheet(isPresented: isPresented) {
                NavigationStack {
                    Form {
                        Section("About") {
                            LabeledContent("Version", value: version)
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented.wrappedValue = false }.fontWeight(.semibold)
                        }
                    }
                }
            }
    }

    /// `1.0 (19)`
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }
}

extension View {
    /// ForIT's build has the ForIT icon here, which opens the ForIT panel: the account, Settings, Send feedback;
    /// this one has a Settings gear at the trailing end of the top bar, and its sheet: the version.
    func squelchProfileMenu(isSettingsPresented: Binding<Bool>) -> some View {
        modifier(SettingsSheet(isPresented: isSettingsPresented))
    }
    /// A small title in the bar.
    func squelchInlineTitle() -> some View { navigationBarTitleDisplayMode(.inline) }
    /// ForIT's build puts its feedback sheet and tint on the app's root; this one has the system's tint.
    func squelchRoot(_ account: FeedbackAccount) -> some View { self }
    /// ForIT's build draws true black behind each screen in dark mode; this one has the system's background.
    func squelchScreen() -> some View { self }
    /// A screen's one primary action.
    func squelchPrimaryButton() -> some View { buttonStyle(.borderedProminent) }
    /// Every other action.
    func squelchSecondaryButton() -> some View { buttonStyle(.bordered) }
}

extension Color {
    /// Text and symbols on a tint fill.
    static var onSquelchTint: Color { .white }
}

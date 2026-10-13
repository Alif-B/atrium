import SwiftUI

struct GeneralSettingsView: View {
    let store: AppStore
    @Bindable var prefs: Preferences
    let previewSound: @MainActor (String) -> Void
    private static let sounds = ["Glass", "Tink", "Ping", "Pop", "Hero", "Funk", "Submarine", "Bottle", "Frog", "Purr"]

    var body: some View {
        Form {
            Section("Windows") {
                Toggle("Place apps inside Atrium", isOn: $prefs.snapOnSwitch)
                Toggle("Show unread badges", isOn: $prefs.showBadges)
            }
            Section("Notifications") {
                Toggle("Play a sound when something new arrives", isOn: $prefs.playBadgeSound)
                Picker("Sound", selection: $prefs.badgeSoundName) {
                    ForEach(Self.sounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!prefs.playBadgeSound)
                .onChange(of: prefs.badgeSoundName) { _, name in previewSound(name) }
                Text("Atrium plays this when an app's unread count goes up while you're looking at another app. Apps also keep their own notifications, controlled in System Settings ▸ Notifications.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Reopen the last app when Atrium starts", isOn: $prefs.restoreLastApp)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if store.isAXTrusted {
                        Label("On", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    } else {
                        HStack(spacing: 8) {
                            Label("Off", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(Color(nsColor: .systemOrange))
                            Button("Open System Settings…") {
                                _ = AX.isTrusted(prompt: true)
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
                LabeledContent("Screen Recording") {
                    if WindowSnapshotter.hasPermission {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
                    } else {
                        HStack(spacing: 8) {
                            Label("Off", systemImage: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                            Button("Open System Settings…") {
                                WindowSnapshotter.requestPermission()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
                Text("Atrium uses Accessibility to place your apps' windows inside it and keep them there, and Screen Recording only to show a still image of the current app while you move Atrium or switch apps. Nothing is saved or sent anywhere.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
    }
}

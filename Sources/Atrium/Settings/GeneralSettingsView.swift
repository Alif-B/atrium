import SwiftUI

struct GeneralSettingsView: View {
    let store: AppStore
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section("Windows") {
                Toggle("Place apps inside Atrium", isOn: $prefs.snapOnSwitch)
                Toggle("Show unread badges", isOn: $prefs.showBadges)
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
                Text("Atrium uses Accessibility to place your apps' windows inside it and keep them there.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
    }
}

import SwiftUI
import AtriumCore

/// Sheet: turn a website into a sidebar app hosted in its own Microsoft Edge window.
struct AddWebAppView: View {
    let store: AppStore
    let onDone: @MainActor () -> Void

    @State private var address = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var working = false
    @State private var error: String?
    /// A picture the user chose (already rendered to an icon file); nil = fetch the site's own icon.
    @State private var customIconPath: String?
    @FocusState private var addressFocused: Bool

    private var url: URL? { WebAddress.normalize(address) }
    private var canAdd: Bool { url != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !working && WebAppManager.isEdgeInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let customIconPath, let image = NSImage(contentsOfFile: customIconPath) {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 52, height: 52)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                        .frame(width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Web App").font(.title3.weight(.semibold))
                    Text("Opens in its own Microsoft Edge window, with no tabs or toolbar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                field("Website") {
                    TextField("", text: $address, prompt: Text("yourcompany.atlassian.net"))
                        .textFieldStyle(.roundedBorder)
                        .focused($addressFocused)
                        .onSubmit { if canAdd { add() } }
                }
                field("Name") {
                    TextField("", text: Binding(get: { name }, set: { name = $0; nameEdited = true }), prompt: Text("Jira"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canAdd { add() } }
                }
            }

            HStack(spacing: 8) {
                Button("Choose Icon…") { chooseIcon() }
                if customIconPath != nil { Button("Use the Site's Icon") { customIconPath = nil } }
                Spacer()
            }
            .disabled(working)
            Text(customIconPath == nil ? "The icon is taken from the website unless you choose one." : "Using the picture you chose.")
                .font(.footnote).foregroundStyle(.secondary)

            Text("Links that open a new tab go to your regular Edge window. You stay signed in with your Edge profile.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !WebAppManager.isEdgeInstalled {
                Label("Microsoft Edge isn't installed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Color(nsColor: .systemOrange))
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Color(nsColor: .systemOrange))
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(customIconPath == nil ? "Getting the site's icon…" : "Preparing the icon…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { addressFocused = true }
        .onChange(of: address) {
            error = nil
            if !nameEdited, let url { name = WebAddress.suggestedName(for: url) }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseIcon() {
        guard let image = IconChooser.chooseImage() else { return }
        let label = name.trimmingCharacters(in: .whitespaces)
        working = true
        Task {
            customIconPath = await SiteIconFetcher.makeIcon(from: image, name: label.isEmpty ? "?" : label, id: "custom-" + UUID().uuidString)
            working = false
        }
    }

    private func add() {
        guard let url else { error = "That doesn't look like a web address."; return }
        let displayName = name.trimmingCharacters(in: .whitespaces)
        let id = ManagedApp.webAppIDPrefix + UUID().uuidString
        working = true
        Task {
            let icon: String?
            if let customIconPath { icon = customIconPath } else { icon = await SiteIconFetcher.makeIcon(for: url, name: displayName, id: id) }
            store.add(ManagedApp(bundleIdentifier: id, displayName: displayName, lastKnownPath: "",
                                 webURL: url.absoluteString, browserBundleID: WebAppManager.edgeBundleID, iconFile: icon,
                                 customIcon: customIconPath != nil))
            working = false
            onDone()
        }
    }
}

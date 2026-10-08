import SwiftUI
import AtriumCore

/// Edit a web app after it was added: its name and its icon (a picture from the Mac, or back to the site's own).
struct EditWebAppView: View {
    let store: AppStore
    let appID: String                     // bundle identifier of the web app
    let onDone: @MainActor () -> Void

    @State private var name: String
    @State private var iconFile: String?
    @State private var customIcon: Bool
    @State private var working = false
    private let originalIconFile: String?

    init(store: AppStore, app: ManagedApp, onDone: @escaping @MainActor () -> Void) {
        self.store = store
        self.appID = app.bundleIdentifier
        self.onDone = onDone
        _name = State(initialValue: app.displayName)
        _iconFile = State(initialValue: app.iconFile)
        _customIcon = State(initialValue: app.customIcon)
        originalIconFile = app.iconFile
    }

    private var app: ManagedApp? { store.apps.first { $0.bundleIdentifier == appID } }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    Button("Choose Icon…") { chooseIcon() }
                    Button("Use the Site's Icon") { useSiteIcon() }
                        .disabled(!customIcon && working)
                    Text(customIcon ? "Using a picture you chose." : "Using the website's own icon.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                TextField("", text: $name).textFieldStyle(.roundedBorder).onSubmit { if canSave { save() } }
            }
            if let site = app?.webURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Website").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(site).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { discardUnsavedIcon(); onDone() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    @ViewBuilder private var preview: some View {
        if let iconFile, let image = IconCache.shared.image(atPath: iconFile) ?? NSImage(contentsOfFile: iconFile) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 88, height: 88)
        } else if let app {
            Image(nsImage: store.icon(for: app)).resizable().interpolation(.high).frame(width: 88, height: 88)
        }
    }

    private func chooseIcon() {
        guard let image = IconChooser.chooseImage() else { return }
        let label = name.trimmingCharacters(in: .whitespaces)
        working = true
        Task {
            let new = await SiteIconFetcher.makeIcon(from: image, name: label.isEmpty ? "?" : label, id: "custom-" + UUID().uuidString)
            discardUnsavedIcon()
            if let new { iconFile = new; customIcon = true }
            working = false
        }
    }

    private func useSiteIcon() {
        guard let app, let site = app.webURL.flatMap(URL.init(string:)) else { return }
        working = true
        Task {
            let new = await SiteIconFetcher.makeIcon(for: site, name: name, id: appID)
            discardUnsavedIcon()
            iconFile = new
            customIcon = false
            working = false
        }
    }

    /// Icons made during this edit that were never saved are deleted, so cancelling leaves nothing behind.
    private func discardUnsavedIcon() {
        if let iconFile, iconFile != originalIconFile { try? FileManager.default.removeItem(atPath: iconFile) }
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newIcon = iconFile
        let isCustom = customIcon
        store.update(bundleID: appID) {
            $0.displayName = newName
            $0.iconFile = newIcon
            $0.customIcon = isCustom
        }
        if let originalIconFile, originalIconFile != newIcon { try? FileManager.default.removeItem(atPath: originalIconFile) }
        onDone()
    }
}

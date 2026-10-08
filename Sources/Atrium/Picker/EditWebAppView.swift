import SwiftUI
import AtriumCore

/// Edit a web app after it was added: its name and its icon (a picture from the Mac at a size you choose, or back to
/// the site's own). Nothing is written to disk until Save, except a re-fetched site icon, which Cancel removes.
struct EditWebAppView: View {
    let store: AppStore
    let appID: String                     // bundle identifier of the web app
    let onDone: @MainActor () -> Void

    @State private var name: String
    @State private var sourceImage: NSImage?        // the user's picture, when the icon is a custom one
    @State private var sourceChanged = false        // a different picture than the saved one
    @State private var scale: Double
    @State private var preview: NSImage?
    @State private var siteIconPath: String?        // a freshly fetched site icon, not saved yet
    @State private var working = false
    private let original: ManagedApp

    init(store: AppStore, app: ManagedApp, onDone: @escaping @MainActor () -> Void) {
        self.store = store
        self.appID = app.bundleIdentifier
        self.onDone = onDone
        self.original = app
        _name = State(initialValue: app.displayName)
        _scale = State(initialValue: app.iconScale ?? SiteIconFetcher.defaultScale)
        let source = app.iconSource.flatMap { NSImage(contentsOfFile: $0) }
        _sourceImage = State(initialValue: app.customIcon ? source : nil)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !working }
    /// True while the icon is one the user chose (and we still have the picture, so it can be resized).
    private var isResizable: Bool { sourceImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                if isResizable {
                    IconSizeControl(preview: preview ?? SiteIconFetcher.customPreview(sourceImage!, scale: scale), scale: $scale)
                        .onChange(of: scale) { preview = SiteIconFetcher.customPreview(sourceImage!, scale: scale) }
                } else {
                    currentIcon
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Choose Icon…") { chooseIcon() }
                    Button("Use the Site's Icon") { useSiteIcon() }
                        .disabled(sourceImage == nil && siteIconPath == nil && !original.customIcon)
                    Text(statusLine).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                TextField("", text: $name).textFieldStyle(.roundedBorder).onSubmit { if canSave { save() } }
            }
            if let site = original.webURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Website").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(site).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var statusLine: String {
        if isResizable { return "Using your picture. Drag the slider to change how big it looks." }
        if original.customIcon && sourceImage == nil && siteIconPath == nil { return "Using a picture you chose earlier. Choose it again to change its size." }
        return "Using the website's own icon."
    }

    @ViewBuilder private var currentIcon: some View {
        let image: NSImage? = siteIconPath.flatMap { NSImage(contentsOfFile: $0) } ?? store.apps.first { $0.bundleIdentifier == appID }.map { store.icon(for: $0) }
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 96, height: 96)
        }
    }

    private func chooseIcon() {
        guard let image = IconChooser.chooseImage() else { return }
        discardFetchedSiteIcon()
        sourceImage = image
        sourceChanged = true
        scale = SiteIconFetcher.defaultScale
        preview = SiteIconFetcher.customPreview(image, scale: scale)
    }

    private func useSiteIcon() {
        guard let site = original.webURL.flatMap(URL.init(string:)) else { return }
        working = true
        Task {
            let path = await SiteIconFetcher.makeIcon(for: site, name: name, id: appID)
            discardFetchedSiteIcon()
            siteIconPath = path
            sourceImage = nil
            sourceChanged = false
            preview = nil
            working = false
        }
    }

    private func discardFetchedSiteIcon() {
        if let siteIconPath { try? FileManager.default.removeItem(atPath: siteIconPath) }
        siteIconPath = nil
    }

    private func cancel() {
        discardFetchedSiteIcon()
        onDone()
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespaces)
        var icon = original.iconFile, source = original.iconSource, savedScale = original.iconScale, isCustom = original.customIcon

        if let image = sourceImage {
            // A custom picture: re-render at the chosen size (reusing the stored original unless a new one was chosen).
            if let saved = SiteIconFetcher.saveCustom(source: image, scale: scale, id: appID,
                                                      existingSource: sourceChanged ? nil : original.iconSource) {
                icon = saved.icon; source = saved.source; savedScale = scale; isCustom = true
            }
        } else if let siteIconPath {
            icon = siteIconPath; source = nil; savedScale = nil; isCustom = false
            self.siteIconPath = nil                        // now owned by the app
        }

        let finalIcon = icon, finalSource = source, finalScale = savedScale, finalCustom = isCustom
        store.update(bundleID: appID) {
            $0.displayName = newName
            $0.iconFile = finalIcon
            $0.iconSource = finalSource
            $0.iconScale = finalScale
            $0.customIcon = finalCustom
        }
        // Remove files this edit replaced.
        if let old = original.iconFile, old != finalIcon { try? FileManager.default.removeItem(atPath: old) }
        if let old = original.iconSource, old != finalSource { try? FileManager.default.removeItem(atPath: old) }
        onDone()
    }
}

import SwiftUI
import AppKit
import AtriumCore
import UniformTypeIdentifiers

struct AddAppsView: View {
    let store: AppStore
    let onDone: @MainActor () -> Void
    var topInset: CGFloat = 28          // room for the transparent titlebar

    @State private var installed: [InstalledApp] = []
    @State private var loaded = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var showingWebApp = false

    private var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? installed : installed.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var suggested: [InstalledApp] {
        filtered.filter { InstalledAppsCatalog.suggestedBundleIDs.contains($0.bundleID) }
    }
    private var webApps: [InstalledApp] { filtered.filter(InstalledAppsCatalog.isSafariWebApp) }
    private var everything: [InstalledApp] { filtered }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.top, topInset)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !suggested.isEmpty { section("Suggested", suggested) }
                    if query.isEmpty {
                        if webApps.isEmpty {
                            Text("Use a web app like Gmail? In Safari choose File ▸ Add to Dock…, then it appears here.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            section("Safari Web Apps", webApps)
                        }
                    }
                    section("All Apps", everything)
                    if !loaded { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Choose Other…") { chooseOther() }
                Button("Add Web App…") { showingWebApp = true }
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
        .task {
            installed = await InstalledAppsCatalog.scan()
            loaded = true
        }
        .onAppear { searchFocused = true }
        .sheet(isPresented: $showingWebApp) {
            AddWebAppView(store: store, onDone: { showingWebApp = false })
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func section(_ title: String, _ apps: [InstalledApp]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ForEach(apps) { app in AppTile(app: app, isAdded: store.contains(bundleID: app.bundleID)) { toggle(app) } }
            }
        }
    }

    private func toggle(_ app: InstalledApp) {
        if store.contains(bundleID: app.bundleID) {
            store.remove(bundleID: app.bundleID)
        } else {
            store.add(ManagedApp(bundleIdentifier: app.bundleID, displayName: app.name, lastKnownPath: app.path))
        }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            store.add(ManagedApp(bundleIdentifier: id, displayName: name, lastKnownPath: url.path))
        }
    }
}

private struct AppTile: View {
    let app: InstalledApp
    let isAdded: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: IconCache.shared.icon(forPath: app.path))
                    .resizable().interpolation(.high)
                    .frame(width: 56, height: 56)
                    .overlay(alignment: .topTrailing) {
                        if isAdded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 6, y: -4)
                        }
                    }
                Text(app.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 96, height: 104)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isAdded ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovered ? 0.05 : 0))
            }
            .overlay(alignment: .topLeading) {
                if InstalledAppsCatalog.isBrowserPWA(app) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .help("For best results, create this with Safari ▸ File ▸ Add to Dock.")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(app.name))
        .accessibilityValue(Text(isAdded ? "added" : "not added"))
    }
}

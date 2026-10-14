import SwiftUI
import AtriumCore

struct AppsSettingsView: View {
    let store: AppStore
    let showAddApps: @MainActor () -> Void
    let editWebApp: @MainActor (ManagedApp) -> Void
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.apps) { app in
                    row(app).tag(app.bundleIdentifier)
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .overlay {
                if store.apps.isEmpty {
                    ContentUnavailableView("No apps yet", systemImage: "square.grid.2x2",
                                           description: Text("Click + to add the apps you want in the sidebar."))
                }
            }
            Divider()
            HStack(spacing: 2) {
                Button { showAddApps() } label: { Image(systemName: "plus") }
                    .help("Add apps")
                    .accessibilityLabel("Add apps")
                Button {
                    if let selection { store.remove(bundleID: selection); self.selection = nil }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected app")
                    .accessibilityLabel("Remove selected app")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 520, height: 400)
    }

    private func row(_ app: ManagedApp) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: store.icon(for: app))
                .resizable().interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(store.isMissing(app) ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName).font(.system(size: 13, weight: .medium))
                Text(store.isMissing(app) ? "Can't find this app" : (app.webURL ?? store.resolvedURL(for: app)?.path ?? app.lastKnownPath))
                    .font(.system(size: 11))
                    .foregroundStyle(store.isMissing(app) ? Color(nsColor: .systemOrange) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Menu {
                Toggle("Snap Window When Opened", isOn: Binding(
                    get: { app.snapWindow },
                    set: { value in store.update(bundleID: app.bundleIdentifier) { $0.snapWindow = value } }))
                Toggle("Open at Login", isOn: Binding(
                    get: { app.openAtLogin },
                    set: { value in store.update(bundleID: app.bundleIdentifier) { $0.openAtLogin = value } }))
                Toggle("Hibernate When Unused", isOn: Binding(
                    get: { app.hibernates },
                    set: { value in store.update(bundleID: app.bundleIdentifier) { $0.hibernates = value } }))
                Button("Edit…") { editWebApp(app) }
                Divider()
                Button("Remove from Sidebar", role: .destructive) { store.remove(bundleID: app.bundleIdentifier) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(app.displayName)")
        }
        .padding(.vertical, 2)
    }
}

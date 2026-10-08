import SwiftUI
import AtriumCore

/// Edit window for a regular Mac app: its hibernation setting (name and icon come from the app itself).
struct EditAppView: View {
    let store: AppStore
    let onDone: @MainActor () -> Void
    private let app: ManagedApp
    @State private var hibernates: Bool

    init(store: AppStore, app: ManagedApp, onDone: @escaping @MainActor () -> Void) {
        self.store = store
        self.app = app
        self.onDone = onDone
        _hibernates = State(initialValue: app.hibernates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: store.icon(for: app)).resizable().interpolation(.high).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName).font(.title3.weight(.semibold))
                    Text(store.resolvedURL(for: app)?.path ?? app.lastKnownPath)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HibernationSection(isOn: $hibernates)
            HStack {
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Save") {
                    store.update(bundleID: app.bundleIdentifier) { $0.hibernates = hibernates }
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

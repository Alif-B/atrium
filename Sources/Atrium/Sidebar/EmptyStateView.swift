import SwiftUI
import AtriumCore

/// What fills Atrium's workspace when the selected app has no window to show (so it is never just an empty gap).
enum EmptyState: Equatable {
    case opening(String)      // launching / waiting for its first window
    case quit(String)         // it quit or crashed (or a web app's window was closed)
    case asleep(String)       // hibernated
    case failed(String)       // never showed a window

    var appID: String {
        switch self { case .opening(let id), .quit(let id), .asleep(let id), .failed(let id): id }
    }
}

struct EmptyStateView: View {
    let store: AppStore
    let open: @MainActor (ManagedApp) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let state = store.emptyState, let app = store.apps.first(where: { $0.bundleIdentifier == state.appID }) {
                card(state, app)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: store.emptyState)
    }

    private func card(_ state: EmptyState, _ app: ManagedApp) -> some View {
        let opening = { if case .opening = state { return true } else { return false } }()
        return VStack(spacing: 14) {
            Image(nsImage: store.icon(for: app))
                .resizable().interpolation(.high)
                .frame(width: 72, height: 72)
                .saturation(opening ? 1 : 0)
                .opacity(opening ? 1 : 0.7)
            VStack(spacing: 4) {
                Text(title(state, app)).font(.title3.weight(.semibold))
                if let detail = detail(state) {
                    Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            if opening {
                ProgressView().controlSize(.small).padding(.top, 2)
            } else {
                Button(buttonTitle(state)) { open(app) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .accessibilityElement(children: .combine)
    }

    private func title(_ state: EmptyState, _ app: ManagedApp) -> String {
        switch state {
        case .opening: "Opening \(app.displayName)…"
        case .quit: app.isWebApp ? "\(app.displayName) was closed" : "\(app.displayName) quit"
        case .asleep: "\(app.displayName) is asleep"
        case .failed: "\(app.displayName) didn't open a window"
        }
    }

    private func detail(_ state: EmptyState) -> String? {
        switch state {
        case .opening: nil
        case .quit: "Open it again to pick up where you left off."
        case .asleep: "It was put to sleep after 15 minutes without use."
        case .failed: "It may still be starting, or waiting in the menu bar."
        }
    }

    private func buttonTitle(_ state: EmptyState) -> String {
        switch state {
        case .opening: ""
        case .quit: "Reopen"
        case .asleep: "Wake"
        case .failed: "Try Again"
        }
    }
}

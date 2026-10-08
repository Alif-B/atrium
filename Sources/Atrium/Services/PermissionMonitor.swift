import Foundation

/// Polls Accessibility trust so the UI (amber dot on the gear) and snapping react without a relaunch.
@MainActor
final class PermissionMonitor {
    private let store: AppStore
    private var task: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
        store.isAXTrusted = AX.isTrusted(prompt: false)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let trusted = AX.isTrusted(prompt: false)
                if trusted != self.store.isAXTrusted { self.store.isAXTrusted = trusted }
            }
        }
    }
}

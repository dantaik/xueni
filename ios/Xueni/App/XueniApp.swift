// XueniApp.swift — the app: two stores, one hub, five tabs.

import SwiftData
import SwiftUI

@main
struct XueniApp: App {
    private let container: ModelContainer
    private let prefs: Preferences
    private let hub: ReaderHub
    private let state = AppState()

    init() {
        let container: ModelContainer
        do {
            container = try Containers.make()
        } catch {
            // A disk that refuses is not a reason to show nothing: read into memory for this session.
            print("stores: falling back to memory: \(error)")
            container = Containers.inMemory()
        }
        self.container = container
        let prefs = Preferences()
        self.prefs = prefs
        hub = ReaderHub(prefs: prefs, cache: CacheStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(prefs)
                .environment(hub)
                .environment(state)
                .tint(.primary)
        }
        .modelContainer(container)
    }
}

/// What crosses between tabs: which tab is up, and a reply waiting to be
/// written. The patch is handed over in memory rather than through
/// storage: it belongs to this navigation, not to the phone.
@MainActor
@Observable
final class AppState {
    enum Tab: Hashable { case read, following, search, write, settings }

    var tab: Tab = .read
    var pendingReply: PendingReply?

    struct PendingReply {
        let chainId: Int
        let txHash: String
        let eventIndex: Int
        let title: String
    }
}

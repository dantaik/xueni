// RootView.swift — the tabs, and where a route leads.

import SwiftUI
import XueniKit

/// Every place a page can push to.
enum Route: Hashable {
    case post(chainId: Int, txHash: String, eventIndex: Int)
    /// A post named by hash alone (a pasted link): found on whichever chain has it.
    case locate(txHash: String, eventIndex: Int)
    case author(String)
    case tag(String)
    case scan
    case endpoints(chainId: Int)
}

/// One tab's navigation stack, reachable by any view inside it.
@MainActor
@Observable
final class Router {
    var path = NavigationPath()

    func push(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var state = state
        let s = prefs.strings
        TabView(selection: $state.tab) {
            TabStack { FeedView() }
                .tabItem { Label(s["tab.read"], systemImage: "book") }
                .tag(AppState.Tab.read)
            TabStack { FollowingView() }
                .tabItem { Label(s["tab.following"], systemImage: "person.2") }
                .tag(AppState.Tab.following)
            TabStack { SearchView() }
                .tabItem { Label(s["tab.search"], systemImage: "magnifyingglass") }
                .tag(AppState.Tab.search)
            TabStack { WriteView() }
                .tabItem { Label(s["tab.write"], systemImage: "square.and.pencil") }
                .tag(AppState.Tab.write)
            TabStack { SettingsView() }
                .tabItem { Label(s["tab.settings"], systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
        }
    }
}

/// A navigation stack with its own router, resolving every route.
struct TabStack<Content: View>: View {
    @State private var router = Router()
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            content()
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route)
                }
        }
        .environment(router)
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .post(let chainId, let txHash, let eventIndex):
            PostView(chainId: chainId, txHash: txHash, eventIndex: eventIndex)
        case .locate(let txHash, let eventIndex):
            LocateView(txHash: txHash, eventIndex: eventIndex)
        case .author(let address):
            AuthorView(address: address)
        case .tag(let tag):
            TagView(tag: tag)
        case .scan:
            ScanView()
        case .endpoints(let chainId):
            EndpointsView(chainId: chainId)
        }
    }
}

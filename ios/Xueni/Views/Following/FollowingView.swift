// FollowingView.swift — the cheap path, used as designed.
//
// A reader who follows authors needs no range scan at all: one head read
// per author per chain, then a walk down single blocks. A divider marks
// where the reader got to last time.

import SwiftData
import SwiftUI
import XueniKit

struct FollowingView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var state
    @Query(sort: \FollowedAuthor.addedAt) private var follows: [FollowedAuthor]

    var body: some View {
        let s = prefs.strings
        let addresses = follows.map { $0.address }
        Group {
            if addresses.isEmpty {
                EmptyStateView(title: s["following.empty"], text: s["following.emptyBody"], actionTitle: s["tab.read"]) { state.tab = .read }
            } else {
                feed(addresses, s)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(s["following.title"]).font(Font.system(.headline, design: .serif, weight: .semibold))
            }
        }
    }

    private func feed(_ addresses: [String], _ s: Strings) -> some View {
        let feed = hub.followFeed(addresses)
        let snap = hub.followSnapshot(addresses)
        let seen = prefs.seenTs
        return List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.t("following.subtitle", ["count": String(addresses.count)]) + (snap.silent.isEmpty ? "" : " · " + s.t("following.silent", ["count": String(snap.silent.count)])))
                        .font(Typo.micro).foregroundStyle(Ink.faint)
                    if snap.scanning && snap.rows.isEmpty {
                        Text(s["following.reading"]).font(Typo.micro).foregroundStyle(Ink.faint)
                    }
                }
                .listRowSeparator(.hidden)
                ForEach(Array(Set(snap.walks.filter { $0.error != nil }.map { $0.chainId })).sorted(), id: \.self) { chainId in
                    if let error = snap.walks.first(where: { $0.chainId == chainId && $0.error != nil })?.error {
                        ErrorLine(message: error) { Task { await feed.retry(chainId: chainId) } }.listRowSeparator(.hidden)
                    }
                }
                if snap.rows.isEmpty && !snap.scanning && snap.walks.allSatisfy({ $0.refreshedAt != nil || $0.error != nil }) {
                    EmptyStateView(title: s["following.nothingYet"], text: s["following.nothingYetBody"]).listRowSeparator(.hidden)
                }
                if let frontier = snap.frontier, frontier.after == -1 {
                    FrontierNote(frontier: frontier, isAuthorList: true, scanning: snap.scanning) { Task { await feed.loadMore() } }.listRowSeparator(.hidden)
                }
                ForEach(Array(snap.rows.enumerated()), id: \.element.id) { i, row in
                    if seen > 0, i > 0, let ts = row.ts, ts <= seen, (snap.rows[i - 1].ts ?? 0) > seen {
                        HStack(spacing: 8) {
                            Hairline()
                            Text(s.t("following.newSince", ["when": Times.relative(seen, lang: prefs.lang, exact: true) ?? ""]))
                                .font(Typo.micro).foregroundStyle(Ink.faint).fixedSize()
                            Hairline()
                        }
                        .listRowSeparator(.hidden)
                    }
                    NavigationLink(value: Route.post(chainId: row.chainId, txHash: row.row.txHash, eventIndex: row.row.eventIndex)) {
                        PostRowView(row: row)
                    }
                    if let frontier = snap.frontier, frontier.after == i {
                        FrontierNote(frontier: frontier, isAuthorList: true, scanning: snap.scanning) { Task { await feed.loadMore() } }.listRowSeparator(.hidden)
                    }
                }
                if !snap.rows.isEmpty {
                    LoadMoreButton(done: snap.done, loading: snap.job != nil) { Task { await feed.loadMore() } }.listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await feed.refresh() }
        .task(id: addresses) { feed.ensureFresh() }
        .onDisappear {
            if let newest = snap.rows.first?.ts { prefs.markSeen(newest) }
        }
    }
}

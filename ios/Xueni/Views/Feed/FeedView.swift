// FeedView.swift — the newest posts from every chain, merged by time.

import SwiftUI
import XueniKit

struct FeedView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @State private var filter: Int? = nil

    private enum Item: Identifiable {
        case row(TimedRow)
        case frontier(Frontier)
        case gap(MergedFeed.Gap)

        var id: String {
            switch self {
            case .row(let r): return r.id
            case .frontier: return "frontier"
            case .gap(let g): return "gap:\(g.chainId):\(g.from)"
            }
        }
    }

    private func items(_ snap: MergedFeed.Snapshot) -> [Item] {
        var out: [Item] = []
        if let f = snap.frontier, f.after == -1 { out.append(.frontier(f)) }
        for (i, row) in snap.rows.enumerated() {
            out.append(.row(row))
            for gap in snap.gaps where gap.after == i { out.append(.gap(gap)) }
            if let f = snap.frontier, f.after == i { out.append(.frontier(f)) }
        }
        return out
    }

    var body: some View {
        let s = prefs.strings
        let feed = hub.feed(chainFilter: filter)
        let snap = hub.feedSnapshot(chainFilter: filter)
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                Text(s["feed.viewAll"]).tag(Int?.none)
                ForEach(Chains.all) { chain in
                    Text(chain.name).tag(Int?.some(chain.id))
                }
            }
            .pickerStyle(.segmented)
            .gutter()
            .padding(.vertical, 10)
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snap.chains, id: \.chainId) { chain in
                            if chain.job != nil {
                                ScanProgressLine(chainId: chain.chainId, job: chain.job, progress: chain.progress, fraction: chain.fraction, budget: chain.scanBlocks)
                            }
                            if let error = chain.error {
                                ErrorLine(message: error) { Task { await feed.retry(chainId: chain.chainId) } }
                            }
                        }
                    }
                    .listRowSeparator(.hidden)

                    if snap.rows.isEmpty && !snap.scanning {
                        EmptyStateView(
                            title: s[snap.done ? "feed.emptyEver" : "feed.emptyRange"],
                            actionTitle: snap.done ? nil : s["feed.scanEarlier"],
                            action: { Task { await feed.loadMore() } }
                        )
                        .listRowSeparator(.hidden)
                    }

                    ForEach(items(snap)) { item in
                        switch item {
                        case .row(let row):
                            NavigationLink(value: Route.post(chainId: row.chainId, txHash: row.row.txHash, eventIndex: row.row.eventIndex)) {
                                PostRowView(row: row)
                            }
                        case .frontier(let frontier):
                            FrontierNote(frontier: frontier, scanning: snap.scanning) { Task { await feed.loadMore() } }
                                .listRowSeparator(.hidden)
                        case .gap(let gap):
                            GapNote(gap: gap, scanning: snap.scanning) { Task { await feed.fillGap(gap) } }
                                .listRowSeparator(.hidden)
                        }
                    }

                    if let note = snap.note {
                        Text(s.t("feed.note", ["chain": Chains.name(of: note.chainId), "blocks": Format.grouped(note.fetched)]))
                            .font(Typo.micro)
                            .foregroundStyle(Ink.faint)
                            .listRowSeparator(.hidden)
                    }

                    if !snap.rows.isEmpty || snap.scanning {
                        LoadMoreButton(done: snap.done, loading: snap.job != nil) { Task { await feed.loadMore() } }
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s["feed.title"]).font(Font.system(.title2, design: .serif, weight: .semibold)).foregroundStyle(Ink.ink)
                        Text(filter.map { s.t("feed.onlyChain", ["chain": Chains.name(of: $0)]) } ?? s.t("feed.subtitleAll", ["count": String(Chains.all.count)]))
                            .font(Typo.micro).foregroundStyle(Ink.faint)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
            .listStyle(.plain)
            .refreshable { await feed.refresh() }
        }
        .task(id: filter) { feed.ensureFresh() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(s["brand"]).font(Font.system(.headline, design: .serif, weight: .semibold))
            }
        }
    }
}

/// Unscanned blocks between two rows of one chain.
struct GapNote: View {
    @Environment(Preferences.self) private var prefs
    let gap: MergedFeed.Gap
    let scanning: Bool
    let action: () -> Void

    var body: some View {
        let s = prefs.strings
        HStack {
            Text(s.t("feed.gapPending", ["chain": Chains.name(of: gap.chainId), "blocks": Format.grouped(gap.to >= gap.from ? gap.to - gap.from + 1 : 0)]))
                .font(Typo.micro).foregroundStyle(Ink.faint)
            Spacer()
            Button(s["feed.scanThisRange"], action: action).buttonStyle(OutlineButtonStyle()).disabled(scanning)
        }
        .padding(.vertical, 4)
    }
}

// SearchView.swift — finding things among what this phone has read.

import SwiftData
import SwiftUI
import XueniKit

struct SearchView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @Query private var bodies: [CachedBody]

    @State private var query = ""
    @State private var index: BodyIndex?
    @State private var resolvedName: (name: String, address: String?)?
    @State private var resolving = false

    var body: some View {
        let s = prefs.strings
        let q = Search.normalize(query)
        List {
            if q.isEmpty {
                Section {
                    Text(s.t("search.scope", ["count": String(index?.count ?? bodies.count)])).font(Typo.micro).foregroundStyle(Ink.faint).listRowSeparator(.hidden)
                    if let index = index {
                        let tags = index.tags()
                        if tags.isEmpty {
                            Text(s["search.noTagsYet"]).font(.subheadline).foregroundStyle(Ink.soft).listRowSeparator(.hidden)
                        } else {
                            ForEach(tags, id: \.tag) { entry in
                                NavigationLink(value: Route.tag(entry.tag)) {
                                    HStack {
                                        Text(entry.tag).font(Font.system(.body, design: .serif))
                                        Spacer()
                                        Text(String(entry.count)).font(Typo.micro).foregroundStyle(Ink.faint).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    SectionLabel(s["search.tagCloud"]).textCase(nil)
                }
            } else {
                Section {
                    directTargets(q, s)
                    if let index = index {
                        let results = index.search(q)
                        if results.isEmpty {
                            EmptyStateView(title: s.t("search.none", ["query": query.trimmingCharacters(in: .whitespaces)]), text: s["search.noneBody"]).listRowSeparator(.hidden)
                        }
                        ForEach(results, id: \.row.id) { result in
                            NavigationLink(value: Route.post(chainId: result.row.chainId, txHash: result.row.txHash, eventIndex: result.row.eventIndex)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Title.forDisplay(result.row.title) ?? s["common.untitled"]).font(Typo.listTitle)
                                    if result.hit.location != .title {
                                        highlighted(result.hit.snippet, q).font(.subheadline).foregroundStyle(Ink.soft).lineLimit(3)
                                    }
                                    HStack(spacing: 8) {
                                        AuthorLabel(address: result.row.author)
                                        ChainMark(chainId: result.row.chainId)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                } header: {
                    Text(s.t("search.scope", ["count": String(index?.count ?? 0)])).font(Typo.micro).foregroundStyle(Ink.faint).textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: s["search.placeholder"])
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: bodies.count) { index = await BodyIndex.build(hub: hub, bodies: bodies) }
        .task(id: q) { await resolveIfName(q) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(s["search.title"]).font(Font.system(.headline, design: .serif, weight: .semibold))
            }
        }
    }

    /// An address, a name, a transaction: the thing itself, above the matches.
    @ViewBuilder
    private func directTargets(_ q: String, _ s: Strings) -> some View {
        if Hex.isAddress(q) {
            NavigationLink(value: Route.author(q)) {
                Label(s.t("search.goToAuthor", ["who": Format.shortAddress(q)]), systemImage: "person")
            }
        } else if ENS.isName(q) {
            if resolving {
                Label(s["search.resolvingName"], systemImage: "person").foregroundStyle(Ink.faint)
            } else if let resolved = resolvedName, resolved.name == q {
                if let address = resolved.address {
                    NavigationLink(value: Route.author(address)) {
                        Label(s.t("search.goToAuthor", ["who": q]), systemImage: "person")
                    }
                } else {
                    Label(s.t("search.noSuchName", ["name": q]), systemImage: "person").foregroundStyle(Ink.faint)
                }
            }
        } else if let ref = PostRef.parse(q) {
            NavigationLink(value: Route.post(chainId: ref.chainId, txHash: ref.txHash, eventIndex: ref.eventIndex)) {
                Label(s.t("search.goToPost", ["what": Format.shortHash(ref.txHash)]), systemImage: "doc.text")
            }
        } else if Hex.isHash(q) {
            NavigationLink(value: Route.locate(txHash: q, eventIndex: 0)) {
                Label(s.t("search.goToPost", ["what": Format.shortHash(q)]), systemImage: "doc.text")
            }
        }
    }

    private func resolveIfName(_ q: String) async {
        guard ENS.isName(q) else { resolvedName = nil; return }
        resolving = true
        let address = await hub.resolve(name: q)
        resolvedName = (q, address)
        resolving = false
    }

    private func highlighted(_ text: String, _ q: String) -> Text {
        Search.highlight(text, query: q).reduce(Text("")) { acc, part in
            acc + (part.hit ? Text(part.text).bold().foregroundColor(Ink.ink) : Text(part.text))
        }
    }
}

struct TagView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @Query private var bodies: [CachedBody]
    let tag: String
    @State private var rows: [PostRow] = []
    @State private var built = false

    var body: some View {
        let s = prefs.strings
        List {
            Section {
                if built && rows.isEmpty {
                    EmptyStateView(title: s.t("tag.none", ["tag": tag]), text: s["search.noneBody"]).listRowSeparator(.hidden)
                }
                ForEach(rows) { row in
                    NavigationLink(value: Route.post(chainId: row.chainId, txHash: row.txHash, eventIndex: row.eventIndex)) {
                        PostRowView(row: TimedRow(row: row, ts: row.ts, exact: true))
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.t("tag.title", ["tag": tag])).font(Font.system(.title2, design: .serif, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(s.t("search.scope", ["count": String(bodies.count)])).font(Typo.micro).foregroundStyle(Ink.faint)
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .task(id: bodies.count) {
            let index = await BodyIndex.build(hub: hub, bodies: bodies)
            rows = index.rows(tag: tag)
            built = true
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// AuthorView.swift — one wallet's posts across both chains, merged by time.

import SwiftData
import SwiftUI
import XueniKit

struct AuthorView: View {
    let address: String

    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @Environment(\.modelContext) private var context
    @Query private var follows: [FollowedAuthor]

    @State private var counts: (total: UInt64?, byChain: [Int: UInt64?])?
    @State private var descriptionText: String?
    @State private var website: String?
    @State private var exportFile: ShareFile?
    @State private var exporting: String?
    @State private var feedback = CopyFeedback()

    init(address: String) {
        let key = address.lowercased()
        self.address = key
        _follows = Query(filter: #Predicate<FollowedAuthor> { $0.address == key })
    }

    private var isFollowing: Bool { !follows.isEmpty }

    var body: some View {
        let s = prefs.strings
        let list = hub.authorList(address)
        let snap = hub.authorSnapshot(address)
        List {
            Section {
                header(snap, s)
                    .listRowSeparator(.hidden)
                ForEach(snap.walks, id: \.chainId) { walk in
                    if let error = walk.error {
                        ErrorLine(message: error) { Task { await list.retry(chainId: walk.chainId) } }
                            .listRowSeparator(.hidden)
                    }
                }
                if let frontier = snap.frontier, frontier.after == -1 {
                    FrontierNote(frontier: frontier, isAuthorList: true, scanning: snap.scanning) { Task { await list.loadMore() } }
                        .listRowSeparator(.hidden)
                }
                if snap.rows.isEmpty && !snap.scanning && snap.walks.allSatisfy({ $0.refreshedAt != nil }) {
                    EmptyStateView(title: s["author.empty"]).listRowSeparator(.hidden)
                }
                ForEach(Array(snap.rows.enumerated()), id: \.element.id) { i, row in
                    NavigationLink(value: Route.post(chainId: row.chainId, txHash: row.row.txHash, eventIndex: row.row.eventIndex)) {
                        PostRowView(row: row, showAuthor: false)
                    }
                    if let frontier = snap.frontier, frontier.after == i {
                        FrontierNote(frontier: frontier, isAuthorList: true, scanning: snap.scanning) { Task { await list.loadMore() } }
                            .listRowSeparator(.hidden)
                    }
                }
                if !snap.rows.isEmpty {
                    LoadMoreButton(done: !snap.hasMore, loading: snap.scanning) { Task { await list.loadMore() } }
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await list.refresh() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu(s) } }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .overlay(alignment: .bottom) {
            if let exporting = exporting {
                Text(exporting).font(Typo.micro).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Ink.ink).foregroundStyle(Ink.paper).clipShape(Capsule()).padding(.bottom, 24)
            } else if feedback.shown {
                Text(s["common.copied"]).font(Typo.micro).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Ink.ink).foregroundStyle(Ink.paper).clipShape(Capsule()).padding(.bottom, 24)
            }
        }
        .task(id: address) {
            list.ensureFresh()
            counts = await hub.counts(author: address)
            if let ens = hub.ens, let name = await ens.name(for: address) {
                descriptionText = await ens.text(name, key: "description")
                website = await ens.text(name, key: "url")
            }
        }
    }

    private func header(_ snap: MergedWalks.Snapshot, _ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                IdenticonView(address: address, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hub.ensName(for: address) ?? Format.shortAddress(address))
                        .font(Font.system(.title2, design: .serif, weight: .semibold))
                    Text(address)
                        .font(Typo.monoSmall)
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .onTapGesture { feedback.copy(address) }
                }
            }
            if let text = descriptionText {
                Text(text).font(.subheadline).foregroundStyle(Ink.soft)
            }
            if let site = website, let url = safeURL(site) {
                Link(url.host ?? site, destination: url).font(Typo.meta).underline()
            }
            HStack(spacing: 12) {
                Button(s[isFollowing ? "following.following" : "following.follow"]) { toggleFollow() }
                    .buttonStyle(isFollowing ? AnyButtonStyle(FilledButtonStyle()) : AnyButtonStyle(OutlineButtonStyle()))
                if let total = counts?.total {
                    Text(s.t("author.total", ["count": String(total)])).font(Typo.meta).foregroundStyle(Ink.soft)
                } else if snap.scanning {
                    Text(s["author.jobRefresh"]).font(Typo.micro).foregroundStyle(Ink.faint)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func safeURL(_ value: String) -> URL? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func toggleFollow() {
        if let existing = follows.first {
            context.delete(existing)
        } else {
            context.insert(FollowedAuthor(address: address))
        }
        try? context.save()
    }

    private func menu(_ s: Strings) -> some View {
        Menu {
            Button { feedback.copy(address) } label: { Label(s["author.copyAddress"], systemImage: "doc.on.doc") }
            ForEach(Chains.all) { chain in
                Link(destination: chain.addressURL(address)) {
                    Label(s.t("author.openExplorer", ["explorer": chain.explorerURL.host ?? chain.name]), systemImage: "arrow.up.right.square")
                }
            }
            Button {
                Task { await exportAuthor() }
            } label: { Label(s["settings.exportAuthor"], systemImage: "archivebox") }
            .disabled(exporting != nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func exportAuthor() async {
        let s = prefs.strings
        exporting = s["settings.archiveWalking"]
        do {
            let doc = await ArchiveBuilder.author(hub: hub, address: address) { done, total in
                exporting = s.t("settings.archiveReading", ["done": String(done), "total": String(total)])
            }
            let url = try ArchiveBuilder.write(doc)
            exportFile = ShareFile(url: url)
        } catch {
            print("archive: \(error)")
        }
        exporting = nil
    }
}

/// One button style or another, decided at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

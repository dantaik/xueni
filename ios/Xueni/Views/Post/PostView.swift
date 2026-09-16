// PostView.swift — one letter, and everything the chain says around it.

import SwiftData
import SwiftUI
import UIKit
import XueniKit

struct PostView: View {
    let chainId: Int
    let txHash: String
    let eventIndex: Int

    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @Environment(Router.self) private var router
    @Environment(AppState.self) private var state

    @State private var row: PostRow?
    @State private var loaded: LoadedBody?
    @State private var blocks: [MarkdownBlock] = []
    @State private var error: String?
    @State private var notFound = false
    @State private var showRaw = false
    @State private var exportFile: ShareFile?
    @State private var relations: BodyIndex.Relations?
    @State private var feedback = CopyFeedback()

    var body: some View {
        let s = prefs.strings
        ScrollView {
            if notFound {
                EmptyStateView(title: s["post.notFound"], text: s["post.notFoundBody"])
            } else if let row = row {
                VStack(alignment: .leading, spacing: 22) {
                    header(row, s)
                    if let loaded = loaded {
                        content(row, loaded, s)
                    } else if let error = error {
                        ErrorLine(message: error) { Task { await load() } }
                    } else {
                        ProgressView().tint(Ink.faint).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .gutter()
                .padding(.vertical, 20)
            } else if let error = error {
                ErrorLine(message: error) { Task { await load() } }.gutter()
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(Ink.faint)
                    Text(s["post.locating"]).font(Typo.micro).foregroundStyle(Ink.faint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu(s) }
        }
        .overlay(alignment: .bottom) {
            if feedback.shown {
                Text(s["common.copied"])
                    .font(Typo.micro)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Ink.ink).foregroundStyle(Ink.paper)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: feedback.shown)
        .sheet(isPresented: $showRaw) {
            if let row = row, let loaded = loaded {
                RawView(row: row, body: loaded)
            }
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .environment(\.openURL, OpenURLAction { url in
            if let route = InlineRenderer.route(for: url) {
                router.push(route)
                return .handled
            }
            return .systemAction
        })
        .task(id: "\(chainId):\(txHash):\(eventIndex)") { await load() }
    }

    // MARK: - Loading

    private func load() async {
        error = nil
        guard let reader = hub.reader(chainId) else { notFound = true; return }
        do {
            guard let found = try await reader.findMeta(txHash: txHash, eventIndex: eventIndex) else {
                notFound = true
                return
            }
            row = found
            hub.authorList(found.author).ensureFresh()
            let body = try await reader.loadBody(found.txHash)
            loaded = body
            let markdown = body.markdown
            blocks = await Task.detached(priority: .userInitiated) { Markdown.parse(markdown) }.value
            hub.noteExcerpt(chainId: chainId, txHash: found.txHash, markdown: markdown)
            let index = await BodyIndex.build(hub: hub, bodies: hub.cache.allBodies())
            relations = index.relations(for: found, seriesName: body.meta["series"])
        } catch {
            self.error = (error as? ChainError)?.text ?? String(describing: error)
        }
    }

    // MARK: - Pieces

    private func header(_ row: PostRow, _ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Title.forDisplay(row.title) ?? s["common.untitled"])
                .font(Typo.pageTitle)
                .foregroundStyle(Title.forDisplay(row.title) == nil ? Ink.faint : Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                NavigationLink(value: Route.author(row.author)) {
                    AuthorLabel(address: row.author, size: 20)
                }
                ChainMark(chainId: row.chainId)
            }
            MetaLine {
                if let when = Times.absolute(row.ts, lang: prefs.lang) { Text(when) }
                Text("·")
                Text(s.t("post.index", ["index": String(Format.ordinal(row.index))]))
                Text("·")
                Text(s.t("common.block", ["block": Format.grouped(row.block)]))
            }
        }
    }

    @ViewBuilder
    private func content(_ row: PostRow, _ loaded: LoadedBody, _ s: Strings) -> some View {
        if !loaded.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(loaded.tags, id: \.self) { tag in
                        NavigationLink(value: Route.tag(tag)) {
                            Text(tag)
                                .font(Typo.micro)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .overlay(Capsule().stroke(Ink.edge, lineWidth: 1))
                        }
                    }
                }
            }
        }
        forwardRelations(row, loaded, s)
        Hairline()
        MarkdownView(blocks: blocks, chainId: row.chainId)
        Hairline()
        provenance(row, loaded, s)
        if let relations = relations, !relations.replies.isEmpty || !relations.continuations.isEmpty || !relations.supersededBy.isEmpty || relations.series.count > 1 {
            reverseRelations(relations, loaded, s)
        }
        neighbours(row, s)
    }

    @ViewBuilder
    private func forwardRelations(_ row: PostRow, _ loaded: LoadedBody, _ s: Strings) -> some View {
        let meta = loaded.meta
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array([("re", "relations.inReplyTo"), ("supersedes", "relations.supersedesLine"), ("prev", "relations.continuesFrom")].enumerated()), id: \.offset) { _, pair in
                let key = pair.0
                let label = pair.1
                if let value = meta[key] {
                    if let ref = PostRef.parse(value, defaultChainId: row.chainId) {
                        NavigationLink(value: Route.post(chainId: ref.chainId, txHash: ref.txHash, eventIndex: ref.eventIndex)) {
                            relationLine(s[label], Format.shortHash(ref.txHash))
                        }
                    } else {
                        relationLine(s[label], value)
                    }
                }
            }
            if let series = meta["series"] {
                if let part = meta["part"] {
                    relationLine(nil, s.t("relations.partOf", ["part": part, "series": series]))
                } else {
                    relationLine(nil, s.t("relations.inSeries", ["series": series]))
                }
            }
            if let lang = meta["lang"] {
                relationLine(s["relations.language"], lang)
            }
        }
    }

    private func relationLine(_ label: String?, _ value: String) -> some View {
        HStack(spacing: 6) {
            if let label = label { Text(label).foregroundStyle(Ink.faint) }
            Text(value).foregroundStyle(Ink.soft).underline(label != nil && value.hasPrefix("0x"))
        }
        .font(Typo.meta)
        .lineLimit(1)
    }

    private func provenance(_ row: PostRow, _ loaded: LoadedBody, _ s: Strings) -> some View {
        let chain = Chains.chain(id: row.chainId)
        return VStack(alignment: .leading, spacing: 8) {
            MetaLine {
                Text(Chains.name(of: row.chainId))
                Text("·")
                Text(s.t("common.block", ["block": Format.grouped(row.block)]))
                Text("·")
                if let chain = chain {
                    Link(destination: chain.txURL(row.txHash)) {
                        Text(Format.shortHash(row.txHash)).underline()
                    }
                }
                if loaded.fromCache {
                    Text("·")
                    Text(s["post.fromCache"])
                }
            }
            if let hook = loaded.hook {
                HStack(spacing: 6) {
                    Text(s["post.viaHook"]).foregroundStyle(Ink.faint)
                    Text(Chains.knownHookKey(hook) == "multi" ? s["hook.multiName"] : Format.shortAddress(hook)).foregroundStyle(Ink.soft)
                }
                .font(Typo.micro)
            }
            if let sender = loaded.sender, loaded.form == .publishFor {
                HStack(spacing: 6) {
                    Text(s["post.relayedBy"]).foregroundStyle(Ink.faint).font(Typo.micro)
                    NavigationLink(value: Route.author(sender)) { AuthorLabel(address: sender) }
                }
            }
            Button(s["raw.show"]) { showRaw = true }.buttonStyle(OutlineButtonStyle())
        }
    }

    private func reverseRelations(_ relations: BodyIndex.Relations, _ loaded: LoadedBody, _ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !relations.supersededBy.isEmpty {
                SectionLabel(s["relations.supersededBy"])
                ForEach(relations.supersededBy) { related in relatedRow(related, s) }
            }
            if !relations.replies.isEmpty {
                SectionLabel(s["relations.replies"])
                ForEach(relations.replies) { related in relatedRow(related, s) }
            }
            if !relations.continuations.isEmpty {
                SectionLabel(s["relations.continuedIn"])
                ForEach(relations.continuations) { related in relatedRow(related, s) }
            }
            if relations.series.count > 1, let series = loaded.meta["series"] {
                SectionLabel(s.t("relations.seriesHeading", ["series": series]))
                ForEach(relations.series, id: \.row.id) { entry in
                    relatedRow(entry.row, s, prefix: entry.part.map { "\($0). " })
                }
            }
            Text(s["relations.knownHere"]).font(Typo.micro).foregroundStyle(Ink.faint)
        }
    }

    private func relatedRow(_ related: PostRow, _ s: Strings, prefix: String? = nil) -> some View {
        NavigationLink(value: Route.post(chainId: related.chainId, txHash: related.txHash, eventIndex: related.eventIndex)) {
            HStack(spacing: 8) {
                Text((prefix ?? "") + (Title.forDisplay(related.title) ?? s["common.untitled"]))
                    .font(Font.system(.subheadline, design: .serif))
                    .foregroundStyle(related.id == row?.id ? Ink.faint : Ink.ink)
                    .lineLimit(1)
                Spacer()
                AuthorLabel(address: related.author, size: 14)
            }
        }
        .disabled(related.id == row?.id)
    }

    private func neighbours(_ row: PostRow, _ s: Strings) -> some View {
        let rows = hub.authorSnapshot(row.author).rows
        let at = rows.firstIndex { $0.id == row.id }
        let newer = at.flatMap { $0 > 0 ? rows[$0 - 1] : nil }
        let older = at.flatMap { $0 + 1 < rows.count ? rows[$0 + 1] : nil }
        return HStack(alignment: .top, spacing: 12) {
            neighbourCard(older, label: s["post.prev"], s: s, alignment: .leading)
            neighbourCard(newer, label: s["post.next"], s: s, alignment: .trailing)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func neighbourCard(_ neighbour: TimedRow?, label: String, s: Strings, alignment: HorizontalAlignment) -> some View {
        if let neighbour = neighbour {
            NavigationLink(value: Route.post(chainId: neighbour.chainId, txHash: neighbour.row.txHash, eventIndex: neighbour.row.eventIndex)) {
                VStack(alignment: alignment, spacing: 4) {
                    Text(label).font(Typo.micro).foregroundStyle(Ink.faint)
                    Text(Title.forDisplay(neighbour.row.title) ?? s["common.untitled"])
                        .font(Font.system(.subheadline, design: .serif, weight: .medium))
                        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.edge, lineWidth: 1))
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 1)
        }
    }

    private func menu(_ s: Strings) -> some View {
        Menu {
            if let row = row {
                Button {
                    feedback.copy(PostRef(chainId: row.chainId, txHash: row.txHash, eventIndex: row.eventIndex).webURL().absoluteString)
                } label: { Label(s["share.copyLink"], systemImage: "link") }
                Button {
                    let title = Title.forDisplay(row.title) ?? s["common.untitled"]
                    feedback.copy("[\(title)](\(row.txHash)\(row.eventIndex == 0 ? "" : "/\(row.eventIndex)"))")
                } label: { Label(s["share.copyRef"], systemImage: "quote.opening") }
                if let loaded = loaded {
                    Button {
                        let name = Files.name(day: row.ts.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(), title: Title.forDisplay(row.title) ?? "untitled", ext: "md")
                        if let url = try? Files.temporary(named: name, data: Data(loaded.text.utf8)) { exportFile = ShareFile(url: url) }
                    } label: { Label(s["share.exportMarkdown"], systemImage: "square.and.arrow.down") }
                    Button { showRaw = true } label: { Label(s["raw.show"], systemImage: "doc.plaintext") }
                }
                Button {
                    state.pendingReply = AppState.PendingReply(chainId: row.chainId, txHash: row.txHash, eventIndex: row.eventIndex, title: Title.forDisplay(row.title) ?? "")
                    state.tab = .write
                } label: { Label(s["share.reply"], systemImage: "arrowshape.turn.up.left") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(s["share.label"])
    }
}

/// The post exactly as the chain holds it: the decompressed document, in
/// monospace, under a line of provenance. The whole design rests on the
/// claim that what is stored is plain, human-readable Markdown; this is
/// where the claim stops being a claim.
struct RawView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Preferences.self) private var prefs
    let row: PostRow
    let body_: LoadedBody
    @State private var feedback = CopyFeedback()

    init(row: PostRow, body: LoadedBody) {
        self.row = row
        self.body_ = body
    }

    var body: some View {
        let s = prefs.strings
        let decompressed = body_.text.utf8.count
        let ratio = body_.compressedBytes > 0 ? Double(decompressed) / Double(body_.compressedBytes) : 0
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MetaLine {
                        Text(s.t("raw.compressed", ["bytes": Format.bytes(body_.compressedBytes)]))
                        Text("·")
                        Text(s.t("raw.decompressed", ["bytes": Format.bytes(decompressed)]))
                        if ratio > 0 {
                            Text("·")
                            Text(s.t("raw.ratio", ["ratio": String(format: "%.1f", ratio)]))
                        }
                    }
                    MetaLine {
                        Text(Chains.name(of: row.chainId))
                        Text("·")
                        Text(s.t("common.block", ["block": Format.grouped(row.block)]))
                    }
                    Text(row.txHash).font(Typo.monoSmall).foregroundStyle(Ink.faint).textSelection(.enabled)
                    if body_.form != .publish || body_.hook != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.t("raw.call", ["call": signature(body_.form)]))
                            if let hook = body_.hook { Text(s.t("raw.hook", ["hook": hook])) }
                            if body_.hookDataHex != "0x" {
                                Text(s.t("raw.hookData", ["bytes": Format.bytes((body_.hookDataHex.count - 2) / 2)]))
                                Text(body_.hookDataHex).lineLimit(3)
                            }
                            if let author = body_.relayedAuthor {
                                Text(s.t("raw.relayed", ["author": Format.shortAddress(author), "sender": Format.shortAddress(body_.sender ?? "")]))
                                if let deadline = body_.relayedDeadline, let ts = Int(deadline) {
                                    Text(s.t("raw.deadline", ["when": Times.absolute(ts, lang: prefs.lang) ?? deadline]))
                                }
                            }
                        }
                        .font(Typo.monoSmall)
                        .foregroundStyle(Ink.soft)
                    }
                    Hairline()
                    Text(body_.text.isEmpty ? " " : body_.text)
                        .font(Typo.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .gutter()
                .padding(.vertical, 16)
            }
            .navigationTitle(s["raw.title"])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(feedback.shown ? s["common.copied"] : s["raw.copyText"]) { feedback.copy(body_.text) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s["common.done"]) { dismiss() }
                }
            }
        }
    }

    private func signature(_ form: CallForm) -> String {
        switch form {
        case .publish: return "publish(bytes32,bytes)"
        case .publishWithHook: return "publish(bytes32,bytes,address,bytes)"
        case .publishFor: return "publishFor(address,bytes32,bytes,address,bytes,uint256,bytes)"
        }
    }
}

/// A post named by hash alone: found on whichever chain has it.
struct LocateView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    let txHash: String
    let eventIndex: Int
    @State private var found: PostRow?
    @State private var missing = false

    var body: some View {
        let s = prefs.strings
        Group {
            if let found = found {
                PostView(chainId: found.chainId, txHash: found.txHash, eventIndex: found.eventIndex)
            } else if missing {
                EmptyStateView(title: s["post.notFound"], text: s["post.notFoundBody"])
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(Ink.faint)
                    Text(s["post.locating"]).font(Typo.micro).foregroundStyle(Ink.faint)
                }
            }
        }
        .task(id: txHash) {
            if let row = await hub.findPostAnywhere(txHash: txHash, eventIndex: eventIndex) { found = row } else { missing = true }
        }
    }
}

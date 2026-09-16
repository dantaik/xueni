// BodyIndex.swift — what the bodies this phone has read actually say.
//
// The contract indexes one thing: an author. Everything else a reader
// might want to find something by — a tag, a reply, a series, a word —
// lives inside the compressed body, where no node can filter on it. So
// the index is local and made of what has already been read, and every
// page built on it says so: it covers the posts this phone has read, and
// reading further back is the way to cover more.

import Foundation
import XueniKit

struct BodyIndex {
    struct Entry: Sendable {
        let chainId: Int
        let txHash: String
        let title: String
        let document: ParsedDocument
        let row: PostRow?
    }

    struct Relations {
        var replies: [PostRow] = []
        var continuations: [PostRow] = []
        var supersededBy: [PostRow] = []
        var series: [(part: Int?, row: PostRow)] = []
    }

    let entries: [Entry]

    /// Build from the cache. Parsing happens off the main actor; rows are
    /// matched from the in-memory stores, which hold every row read.
    @MainActor
    static func build(hub: ReaderHub, bodies: [CachedBody]) async -> BodyIndex {
        let raw: [(Int, String, String)] = bodies.map { ($0.chainId, $0.txHash, $0.text) }
        let parsed = await Task.detached(priority: .userInitiated) { () -> [(Int, String, ParsedDocument)] in
            raw.map { ($0.0, $0.1, Document.parse($0.2)) }
        }.value
        let entries = parsed.map { chainId, txHash, document -> Entry in
            let row = hub.reader(chainId)?.store.knownPost(txHash: txHash, eventIndex: 0)
            return Entry(chainId: chainId, txHash: txHash, title: row?.title ?? "", document: document, row: row)
        }
        return BodyIndex(entries: entries)
    }

    var count: Int { entries.count }

    /// Every tag seen, with how many posts carry it, most used first.
    func tags() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            for tag in entry.document.tags {
                let key = tag.trimmingCharacters(in: .whitespaces).lowercased()
                if !key.isEmpty { counts[key, default: 0] += 1 }
            }
        }
        return counts.map { ($0.key, $0.value) }.sorted { a, b in a.count != b.count ? a.count > b.count : a.tag < b.tag }
    }

    /// Every post this phone has read that carries `tag`, newest first.
    func rows(tag: String) -> [PostRow] {
        let wanted = tag.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { $0.document.tags.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == wanted } }
            .compactMap { $0.row }
            .sorted(by: PostRow.feedBefore)
    }

    /// A word in any title, tag or body, newest first.
    func search(_ query: String) -> [(row: PostRow, hit: SearchHit)] {
        let q = Search.normalize(query)
        guard !q.isEmpty else { return [] }
        return entries.compactMap { entry -> (PostRow, SearchHit)? in
            guard let row = entry.row, let hit = Search.match(title: row.title, tags: entry.document.tags, markdown: entry.document.markdown, query: q) else { return nil }
            return (row, hit)
        }.sorted { PostRow.feedBefore($0.0, $1.0) }
    }

    /// What points at this post, and its series — among the posts read here.
    func relations(for row: PostRow, seriesName: String?) -> Relations {
        var out = Relations()
        let target = PostRef(chainId: row.chainId, txHash: row.txHash, eventIndex: row.eventIndex)
        for entry in entries {
            guard let from = entry.row, from.id != row.id else { continue }
            let meta = entry.document.meta
            if let re = meta["re"], PostRef.parse(re, defaultChainId: entry.chainId) == target { out.replies.append(from) }
            if let prev = meta["prev"], PostRef.parse(prev, defaultChainId: entry.chainId) == target { out.continuations.append(from) }
            if let sup = meta["supersedes"], PostRef.parse(sup, defaultChainId: entry.chainId) == target { out.supersededBy.append(from) }
        }
        if let name = seriesName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty {
            for entry in entries {
                guard let from = entry.row, from.author == row.author else { continue }
                guard let series = entry.document.meta["series"], series.trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
                out.series.append((entry.document.meta["part"].flatMap { Int($0) }, from))
            }
            out.series.sort { ($0.part ?? Int.max) < ($1.part ?? Int.max) }
        }
        out.replies.sort(by: PostRow.feedBefore)
        out.continuations.sort(by: PostRow.feedBefore)
        out.supersededBy.sort(by: PostRow.feedBefore)
        return out
    }
}

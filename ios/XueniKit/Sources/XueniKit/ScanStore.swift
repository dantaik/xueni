// ScanStore.swift — everything the reader has already read from ONE chain.
//
// A port of webapp/src/lib/scanStore.js's session layer: every post this
// process has seen, indexed by (author, index) and by (txHash, eventIndex),
// plus the block ranges genuinely fetched — as a SET of ranges, so a deep
// read spends its budget only on ground no earlier read has touched.
//
// The persisted layer is the app's business (SwiftData, in ../Xueni):
// every mutation here is announced as a `ScanStoreEvent`, which the app
// writes through, and the app seeds a fresh store from what it saved. The
// store itself knows nothing about storage, which is what keeps the
// traversal rules testable on any machine.
//
// One store per chain. Block heights, post indexes and transaction hashes
// mean nothing across chains, so nothing here is shared between them.

import Foundation

/// One post as a list knows it: everything the event says, plus where the
/// post sits and when. The body is elsewhere (it is read on demand).
public struct PostRow: Sendable, Hashable, Codable, Identifiable {
    public var chainId: Int
    /// Lowercase.
    public var author: String
    public var index: UInt64
    public var block: UInt64
    public var prevBlock: UInt64
    public var title: String
    /// Lowercase.
    public var txHash: String
    /// The 0-based ordinal of the Post event within its transaction.
    public var eventIndex: Int
    /// Orders posts published in the same block — the feed's page cursor.
    public var logIndex: Int?
    /// The block's timestamp in seconds, when known.
    public var ts: Int?
    /// The hook the post went through (lowercase), or nil.
    public var hook: String?

    public init(chainId: Int, author: String, index: UInt64, block: UInt64, prevBlock: UInt64, title: String, txHash: String, eventIndex: Int = 0, logIndex: Int? = nil, ts: Int? = nil, hook: String? = nil) {
        self.chainId = chainId
        self.author = author.lowercased()
        self.index = index
        self.block = block
        self.prevBlock = prevBlock
        self.title = title
        self.txHash = txHash.lowercased()
        self.eventIndex = eventIndex
        self.logIndex = logIndex
        self.ts = ts
        self.hook = hook?.lowercased()
    }

    /// Identity across chains: chain, transaction, event.
    public var id: String { "\(chainId):\(txHash):\(eventIndex)" }

    /// Identity within a chain: who wrote it, and which of theirs it is.
    public var postKey: String { "\(author):\(index)" }

    public var txKey: String { "\(txHash):\(eventIndex)" }

    public var ref: PostRef { PostRef(chainId: chainId, txHash: txHash, eventIndex: eventIndex) }

    /// Feed order: newest first — higher block, then higher log index.
    public static func feedBefore(_ a: PostRow, _ b: PostRow) -> Bool {
        if a.block != b.block { return a.block > b.block }
        return (a.logIndex ?? 0) > (b.logIndex ?? 0)
    }

    /// Author order: newest (highest index) first.
    public static func indexBefore(_ a: PostRow, _ b: PostRow) -> Bool {
        a.index > b.index
    }

    /// True when `self` sits strictly older than `cursor` in feed order.
    public func isOlder(than cursor: PostRow) -> Bool {
        if block != cursor.block { return block < cursor.block }
        guard let mine = logIndex, let theirs = cursor.logIndex else { return false }
        return mine < theirs
    }
}

/// What changed in a store, for whoever persists it.
public enum ScanStoreEvent: Sendable {
    case rows([PostRow])
    case feedRange(Segment)
    case authorBlock(author: String, block: UInt64)
    case feedHead(UInt64)
    case authorHead(author: String, head: UInt64)
    case blockTime(block: UInt64, ts: Int)
    case reset
}

/// A registry of change listeners, the same shape everywhere in the Kit.
@MainActor
public final class Listeners {
    private var callbacks: [UUID: () -> Void] = [:]
    public init() {}

    @discardableResult
    public func add(_ fn: @escaping () -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = fn
        return id
    }

    public func remove(_ id: UUID) {
        callbacks[id] = nil
    }

    public func notify() {
        for fn in callbacks.values { fn() }
    }
}

@MainActor
public final class MemoryScanStore {
    public let chainId: Int

    private var posts: [String: PostRow] = [:] // postKey -> row
    private var keyByTx: [String: String] = [:] // txKey -> postKey
    private var keysByBlock: [UInt64: Set<String>] = [:]
    /// Ranges read in full for EVERY author (home-feed window fetches).
    private var feedSegments: [Segment] = []
    /// author -> ranges read in full for that one author (single-block fetches).
    private var authorSegments: [String: [Segment]] = [:]
    /// Chain head at the last completed feed scan.
    private var feedHead: UInt64? = nil
    /// author -> the author's `latestBlock` at their last completed walk.
    private var authorHeads: [String: UInt64] = [:]

    public let listeners = Listeners()
    public private(set) var version = 0
    /// Told of every mutation, for the layer that persists them.
    public var onEvent: ((ScanStoreEvent) -> Void)?

    public init(chainId: Int) {
        self.chainId = chainId
    }

    private func notify() {
        version += 1
        listeners.notify()
    }

    private func emit(_ event: ScanStoreEvent) {
        onEvent?(event)
    }

    // MARK: - Rows

    /// File one row. A post already held stays the canonical row, but a
    /// newcomer fills in what the held one lacks — the log index, the
    /// timestamp, the hook.
    private func index(_ row: PostRow) -> (row: PostRow, changed: Bool) {
        let key = row.postKey
        if var prev = posts[key] {
            var changed = false
            if prev.logIndex == nil, let li = row.logIndex { prev.logIndex = li; changed = true }
            if prev.ts == nil, let ts = row.ts { prev.ts = ts; changed = true }
            if prev.hook == nil, let hook = row.hook { prev.hook = hook; changed = true }
            if changed { posts[key] = prev }
            return (prev, changed)
        }
        posts[key] = row
        keyByTx[row.txKey] = key
        keysByBlock[row.block, default: []].insert(key)
        return (row, true)
    }

    /// Record posts the session has read. Returns the canonical rows.
    @discardableResult
    public func rememberPosts(_ rows: [PostRow]) -> [PostRow] {
        var changed = false
        var changedRows: [PostRow] = []
        let out = rows.map { raw -> PostRow in
            var row = raw
            row.chainId = chainId
            let res = index(row)
            if res.changed {
                changed = true
                changedRows.append(res.row)
            }
            return res.row
        }
        if changed {
            emit(.rows(changedRows))
            notify()
        }
        return out
    }

    /// Seed rows from storage without announcing them back to storage.
    public func seed(rows: [PostRow], feedSegments: [Segment], authorSegments: [String: [Segment]], feedHead: UInt64?, authorHeads: [String: UInt64]) {
        for raw in rows {
            var row = raw
            row.chainId = chainId
            _ = index(row)
        }
        self.feedSegments = Segments.normalize(self.feedSegments + feedSegments)
        for (author, segs) in authorSegments {
            self.authorSegments[author.lowercased()] = Segments.normalize((self.authorSegments[author.lowercased()] ?? []) + segs)
        }
        if let head = feedHead { self.feedHead = head }
        for (author, head) in authorHeads { self.authorHeads[author.lowercased()] = head }
        notify()
    }

    /// A block's timestamp arrived: give it to every row in that block
    /// still without one. Returns whether anything changed.
    @discardableResult
    public func rememberBlockTime(_ block: UInt64, ts: Int) -> Bool {
        guard let keys = keysByBlock[block] else { return false }
        var changed = false
        for key in keys {
            if var row = posts[key], row.ts == nil {
                row.ts = ts
                posts[key] = row
                changed = true
            }
        }
        if changed {
            emit(.blockTime(block: block, ts: ts))
            notify()
        }
        return changed
    }

    /// The timestamp of `block` if any row in it carries one.
    public func knownBlockTime(_ block: UInt64) -> Int? {
        guard let keys = keysByBlock[block] else { return nil }
        for key in keys {
            if let ts = posts[key]?.ts { return ts }
        }
        return nil
    }

    // MARK: - Coverage

    /// Record that `[from, to]` was read in full, for every author.
    public func rememberFeedRange(_ from: UInt64, _ to: UInt64) {
        feedSegments = Segments.add(feedSegments, from, to)
        emit(.feedRange(Segment(from, to)))
        notify()
    }

    /// Record that `block` was read in full for one author.
    public func rememberAuthorBlock(_ author: String, _ block: UInt64) {
        let key = author.lowercased()
        authorSegments[key] = Segments.add(authorSegments[key] ?? [], block, block)
        emit(.authorBlock(author: key, block: block))
        notify()
    }

    /// Ranges proven complete for every author.
    public func feedCoverage() -> [Segment] { feedSegments }

    /// Ranges proven complete for `author` — their own single-block reads
    /// plus the global sweeps, which record every Post event in the range.
    public func authorCoverage(_ author: String) -> [Segment] {
        Segments.normalize((authorSegments[author.lowercased()] ?? []) + feedSegments)
    }

    /// The author's own single-block coverage alone.
    public func authorOwnCoverage(_ author: String) -> [Segment] {
        authorSegments[author.lowercased()] ?? []
    }

    // MARK: - Questions

    public func knownPost(author: String, index: UInt64) -> PostRow? {
        posts["\(author.lowercased()):\(index)"]
    }

    public func knownPost(txHash: String, eventIndex: Int = 0) -> PostRow? {
        guard let key = keyByTx["\(txHash.lowercased()):\(eventIndex)"] else { return nil }
        return posts[key]
    }

    /// Every post the store holds, newest first.
    public func allPosts() -> [PostRow] {
        posts.values.sorted(by: PostRow.feedBefore)
    }

    public var count: Int { posts.count }

    /// Posts inside `[from, to]`, newest first.
    public func posts(from: UInt64, to: UInt64) -> [PostRow] {
        posts.values.filter { $0.block >= from && $0.block <= to }.sorted(by: PostRow.feedBefore)
    }

    /// Posts inside ranges swept for every author, newest first — never
    /// "every post the store knows": a post found by an author walk sits in
    /// an unswept range, and listing it would put a hole in the feed.
    public func coveredPosts() -> [PostRow] {
        var out: [PostRow] = []
        for seg in feedSegments { out.append(contentsOf: posts(from: seg.from, to: seg.to)) }
        return out.sorted(by: PostRow.feedBefore)
    }

    /// One author's posts inside a block, newest index first.
    public func authorPosts(_ author: String, inBlock block: UInt64) -> [PostRow] {
        guard let keys = keysByBlock[block] else { return [] }
        let who = author.lowercased()
        return keys.compactMap { posts[$0] }.filter { $0.author == who }.sorted(by: PostRow.indexBefore)
    }

    /// One author's posts, newest first.
    public func authorPosts(_ author: String) -> [PostRow] {
        let who = author.lowercased()
        return posts.values.filter { $0.author == who }.sorted(by: PostRow.feedBefore)
    }

    /// The author's chain from `fromBlock` down, as far as covered blocks
    /// reach — the rows a completed walk left behind, without any I/O.
    public func knownChain(_ author: String, from fromBlock: UInt64) -> [PostRow] {
        var out: [PostRow] = []
        let coverage = authorCoverage(author)
        var block = fromBlock
        while block > 0, Segments.segment(at: block, in: coverage) != nil {
            let rows = authorPosts(author, inBlock: block)
            if rows.isEmpty { break }
            out.append(contentsOf: rows)
            let next = rows[rows.count - 1].prevBlock
            if next >= block { break }
            block = next
        }
        return out
    }

    // MARK: - Heads

    public func feedScanHead() -> UInt64? { feedHead }

    public func authorScanHead(_ author: String) -> UInt64? { authorHeads[author.lowercased()] }

    public func setFeedScanHead(_ head: UInt64) {
        feedHead = head
        emit(.feedHead(head))
        notify()
    }

    public func setAuthorScanHead(_ author: String, _ head: UInt64) {
        authorHeads[author.lowercased()] = head
        emit(.authorHead(author: author.lowercased(), head: head))
        notify()
    }

    /// Per-author coverage for the scan page, newest head first.
    public struct AuthorScanEntry: Sendable {
        public let address: String
        public let head: UInt64?
        public let segments: [Segment]
        public let count: Int
    }

    public func authorScanEntries() -> [AuthorScanEntry] {
        var seen = Set<String>()
        var out: [AuthorScanEntry] = []
        for (address, segments) in authorSegments {
            seen.insert(address)
            out.append(AuthorScanEntry(address: address, head: authorHeads[address], segments: segments, count: authorPosts(address).count))
        }
        for address in authorHeads.keys where !seen.contains(address) {
            out.append(AuthorScanEntry(address: address, head: authorHeads[address], segments: [], count: authorPosts(address).count))
        }
        return out.sorted { a, b in
            switch (a.head, b.head) {
            case (nil, nil): return a.address < b.address
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?): return x > y
            }
        }
    }

    // MARK: - In-flight fetches

    private var inflight: [String: (id: UUID, task: Task<Void, Error>)] = [:]

    /// Run `body` at most once per `key` at a time: a second caller for the
    /// same block awaits the first's result rather than fetching again.
    public func once(_ key: String, _ body: @escaping @MainActor () async throws -> Void) async throws {
        if let hit = inflight[key] {
            try await hit.task.value
            return
        }
        let id = UUID()
        let task = Task { @MainActor in try await body() }
        inflight[key] = (id, task)
        defer { if inflight[key]?.id == id { inflight[key] = nil } }
        try await task.value
    }

    /// Forget everything (tests, and a cache the reader chose to clear).
    public func reset() {
        inflight.removeAll()
        posts.removeAll()
        keyByTx.removeAll()
        keysByBlock.removeAll()
        authorSegments.removeAll()
        authorHeads.removeAll()
        feedSegments = []
        feedHead = nil
        emit(.reset)
        notify()
    }
}

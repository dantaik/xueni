// ChainReader.swift — everything a page reads, on ONE chain.
//
// A reader bundles a chain's I/O over the reader's own endpoints, its
// in-memory scan store (seeded from the chain cache and written back to
// it), the feed and author-list controllers whose scans run whatever the
// screen shows, and the one-shot reads — a post by link, a body, an image,
// the chain clock — each answered from the cache before the node is asked.
// One per chain, alive for the app.

import Foundation
import XueniKit

/// A post body as a page shows it: the document, what the call around it
/// said, and where it came from.
struct LoadedBody {
    let text: String
    let document: ParsedDocument
    let compressedBytes: Int
    let form: CallForm
    let hook: String?
    let hookDataHex: String
    let relayedAuthor: String?
    let relayedDeadline: String?
    let relayedSignatureHex: String?
    let sender: String?
    let fromCache: Bool

    init(record: CachedBody, fromCache: Bool) {
        text = record.text
        document = Document.parse(record.text)
        compressedBytes = record.compressedBytes
        form = CallForm(rawValue: record.form) ?? .publish
        hook = record.hook
        hookDataHex = record.hookDataHex
        relayedAuthor = record.relayedAuthor
        relayedDeadline = record.relayedDeadline
        relayedSignatureHex = record.relayedSignatureHex
        sender = record.sender
        self.fromCache = fromCache
    }

    var markdown: String { document.markdown }
    var tags: [String] { document.tags }
    var meta: [String: String] { document.meta }
}

@MainActor
final class ChainReader {
    static let pageSize = 20

    let chain: Chain
    let store: MemoryScanStore
    let transport: OrderedTransport
    let io: ChainIO
    let feed: FeedController
    let cache: CacheStore

    private let prefs: Preferences
    private var lists: [String: AuthorListController] = [:]
    private var bodyTasks: [String: Task<LoadedBody, Error>] = [:]
    private var imageTasks: [String: Task<Data, Error>] = [:]
    private var metaTasks: [String: Task<PostRow?, Error>] = [:]
    private var clockCache: (at: Date, clock: ChainClock)?
    private var clockTask: Task<ChainClock, Error>?
    private var countCache: [String: (at: Date, count: UInt64)] = [:]

    init(chain: Chain, cache: CacheStore, prefs: Preferences) {
        self.chain = chain
        self.cache = cache
        self.prefs = prefs
        let transport = OrderedTransport(urls: prefs.rpcURLs(for: chain))
        self.transport = transport
        io = ChainIO(chain: chain, rpc: transport, brotli: AppleBrotli())
        let store = MemoryScanStore(chainId: chain.id)
        self.store = store
        let seed = cache.seed(chainId: chain.id)
        store.seed(rows: seed.rows, feedSegments: seed.feedSegments, authorSegments: seed.authorSegments, feedHead: seed.feedHead, authorHeads: seed.authorHeads)
        feed = FeedController(
            chainId: chain.id,
            store: store,
            io: io,
            windowSize: chain.logWindow,
            floor: chain.deployBlock,
            scanBlocks: chain.scanBlocks,
            pageSize: Self.pageSize,
            rescanDelay: { [prefs] in prefs.rescanDelay }
        )
        store.onEvent = { [weak self] event in
            guard let self else { return }
            self.cache.apply(event, chainId: self.chain.id, store: self.store)
        }
    }

    var chainId: Int { chain.id }

    /// The endpoint list changed in the settings: the next request uses it.
    func applyEndpoints() {
        let urls = prefs.rpcURLs(for: chain)
        Task { await transport.setURLs(urls) }
    }

    // MARK: - Walks

    func authorList(_ author: String) -> AuthorListController {
        let key = author.lowercased()
        if let list = lists[key] { return list }
        let list = AuthorListController(author: key, store: store, io: io, pageSize: Self.pageSize, rescanDelay: { [prefs] in prefs.rescanDelay })
        lists[key] = list
        return list
    }

    var source: ChainSource {
        ChainSource(chainId: chain.id, store: store, clock: { [self] in try await self.clock() }, blockTime: { [self] block in try await self.blockTime(block) })
    }

    // MARK: - The chain's clock

    /// The newest block and the measured pace, held for a minute.
    func clock() async throws -> ChainClock {
        if let hit = clockCache, Date().timeIntervalSince(hit.at) < 60 { return hit.clock }
        if let running = clockTask { return try await running.value }
        let task = Task { try await self.io.clock() }
        clockTask = task
        defer { if clockTask == task { clockTask = nil } }
        let clock = try await task.value
        clockCache = (Date(), clock)
        return clock
    }

    /// When `block` was mined — from a row that carries it, else one header read.
    func blockTime(_ block: UInt64) async throws -> Int {
        if let known = store.knownBlockTime(block) { return known }
        return try await io.blockTime(block)
    }

    /// How many posts `author` has here, held for a minute.
    func count(author: String) async throws -> UInt64 {
        let key = author.lowercased()
        if let hit = countCache[key], Date().timeIntervalSince(hit.at) < 60 { return hit.count }
        let n = try await io.count(author: key)
        countCache[key] = (Date(), n)
        return n
    }

    // MARK: - One post

    /// The row for a transaction and event ordinal: answered from the store
    /// when the post has been seen, else one receipt read, no scanning.
    func findMeta(txHash: String, eventIndex: Int) async throws -> PostRow? {
        let hash = txHash.lowercased()
        if let known = store.knownPost(txHash: hash, eventIndex: eventIndex) { return known }
        let key = "\(hash):\(eventIndex)"
        if let running = metaTasks[key] { return try await running.value }
        let task = Task<PostRow?, Error> { @MainActor in
            let rows = try await self.io.postsInTx(hash)
            // Remember every post in the transaction, not just the one asked for.
            let remembered = self.store.rememberPosts(rows)
            return remembered.first { $0.eventIndex == eventIndex }
        }
        metaTasks[key] = task
        defer { metaTasks[key] = nil }
        return try await task.value
    }

    /// Find one (author, index) — prev/next navigation and deep links.
    func findMeta(author: String, index: UInt64) async throws -> PostRow? {
        if let known = store.knownPost(author: author, index: index) { return known }
        let head = try await io.latestBlock(author: author)
        guard head > 0 else { return nil }
        return try await Scanner.findAuthorPost(store: store, author: author, targetIndex: index, startBlock: head) { block in
            try await self.io.authorPostsInBlock(author: author, block: block)
        }
    }

    /// The body of a post, cache-first. A body read once is kept for good.
    func loadBody(_ txHash: String) async throws -> LoadedBody {
        let hash = txHash.lowercased()
        if let running = bodyTasks[hash] { return try await running.value }
        let task = Task<LoadedBody, Error> { @MainActor in
            if let record = self.cache.body(chainId: self.chain.id, txHash: hash) {
                return LoadedBody(record: record, fromCache: true)
            }
            let body = try await self.io.postBody(hash)
            let record = self.cache.saveBody(chainId: self.chain.id, txHash: hash, post: body.post, sender: body.sender)
            return LoadedBody(record: record, fromCache: false)
        }
        bodyTasks[hash] = task
        do {
            return try await task.value
        } catch {
            bodyTasks[hash] = nil
            throw error
        }
    }

    /// The bytes of an image, cache-first.
    func loadImage(_ txHash: String) async throws -> Data {
        let hash = txHash.lowercased()
        if let running = imageTasks[hash] { return try await running.value }
        let task = Task<Data, Error> { @MainActor in
            if let data = self.cache.image(chainId: self.chain.id, txHash: hash) { return data }
            let bytes = try await self.io.imageBytes(hash)
            let data = Data(bytes)
            self.cache.saveImage(chainId: self.chain.id, txHash: hash, bytes: data)
            return data
        }
        imageTasks[hash] = task
        do {
            return try await task.value
        } catch {
            imageTasks[hash] = nil
            throw error
        }
    }

    /// After the cache was cleared: forget what this session held too.
    func forgetEverything() {
        bodyTasks.removeAll()
        imageTasks.removeAll()
        metaTasks.removeAll()
        lists.removeAll()
        store.reset()
    }
}

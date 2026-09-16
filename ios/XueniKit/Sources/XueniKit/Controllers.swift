// Controllers.swift — scans that outlive the screen showing them.
//
// FeedController owns one chain's sweeps: a job started on the home feed
// keeps running after the reader opens a post, and every window it fetches
// lands in the store the moment it arrives. AuthorListController owns one
// author's walk down the contract's reverse block-linked list on one chain.
// Both are ports of feed.js and authorList.js, over an injected chain I/O
// so that the app and the tests drive the same rules.

import Foundation

/// The chain reads the controllers need. ChainIO implements it over a
/// node; tests implement it over an in-memory chain.
public protocol ChainReadIO: AnyObject, Sendable {
    var chainId: Int { get }
    func blockNumber() async throws -> UInt64
    func blockTime(_ block: UInt64) async throws -> Int
    func postsInRange(from: UInt64, to: UInt64) async throws -> RangeResult
    func authorPostsInBlock(author: String, block: UInt64) async throws -> [PostRow]
    func latestBlock(author: String) async throws -> UInt64
    func count(author: String) async throws -> UInt64
}

public enum JobKind: String, Sendable {
    case refresh
    case more
    case gap
}

// MARK: - The home feed of one chain

@MainActor
public final class FeedController {
    public struct Snapshot: Sendable {
        public var job: JobKind?
        public var progress: SweepProgress?
        public var fraction: Double?
        public var error: String?
        public var head: UInt64?
        public var coverage: [Segment]
        /// The range read continuously from the head down.
        public var top: Segment?
        /// That range reaches the floor: nothing older exists to read.
        public var exhausted: Bool
        public var floor: UInt64
        public var scanBlocks: UInt64
        public var refreshedAt: Date?
    }

    public struct ExtendResult: Sendable {
        public var fetched: UInt64
        public var found: Int
        public var reachedFloor: Bool
    }

    public let chainId: Int
    public let store: MemoryScanStore
    public let listeners = Listeners()

    private let io: ChainReadIO
    private let windowSize: UInt64
    private let floor: UInt64
    private let scanBlocks: UInt64
    private let pageSize: Int
    private let rescanDelay: () -> TimeInterval
    private let now: () -> Date

    /// How far below the reported head a refresh starts: public gateways
    /// answer eth_blockNumber and eth_getLogs from different nodes.
    private let headLag: UInt64 = 1

    private var job: (kind: JobKind, task: Task<ExtendResult?, Never>)?
    private var progress: SweepProgress?
    private var fraction: Double?
    private var error: String?
    private var refreshedAt: Date?

    public init(chainId: Int, store: MemoryScanStore, io: ChainReadIO, windowSize: UInt64, floor: UInt64, scanBlocks: UInt64, pageSize: Int, rescanDelay: @escaping () -> TimeInterval, now: @escaping () -> Date = { Date() }) {
        self.chainId = chainId
        self.store = store
        self.io = io
        self.windowSize = windowSize
        self.floor = floor
        self.scanBlocks = scanBlocks
        self.pageSize = pageSize
        self.rescanDelay = rescanDelay
        self.now = now
        store.listeners.add { [weak self] in self?.listeners.notify() }
    }

    public var snapshot: Snapshot {
        let coverage = store.feedCoverage()
        let top = coverage.last
        return Snapshot(
            job: job?.kind,
            progress: progress,
            fraction: fraction,
            error: error,
            head: store.feedScanHead(),
            coverage: coverage,
            top: top,
            exhausted: top.map { $0.from <= floor } ?? false,
            floor: floor,
            scanBlocks: scanBlocks,
            refreshedAt: refreshedAt
        )
    }

    public var isRunning: Bool { job != nil }

    /// Refresh unless a job is running or the last refresh is still fresh.
    public func ensureFresh() {
        if job != nil { return }
        if let at = refreshedAt, now().timeIntervalSince(at) < rescanDelay() { return }
        Task { await refresh() }
    }

    /// Read whatever was mined since the last refresh (joins a running job).
    @discardableResult
    public func refresh() async -> ExtendResult? {
        await run(.refresh) { try await self.doRefresh(); return nil }
    }

    /// Deepen coverage by a page: sweep from the bottom of the
    /// head-contiguous range down.
    @discardableResult
    public func extend() async -> ExtendResult? {
        await run(.more) { try await self.doExtend() }
    }

    /// Sweep the unswept blocks between two ranges the page straddles.
    public func fillGap(from: UInt64, to: UInt64) async {
        _ = await run(.gap) { try await self.doGap(from: from, to: to); return nil }
    }

    public func retry() async {
        error = nil
        await refresh()
    }

    private func run(_ kind: JobKind, _ body: @escaping @MainActor () async throws -> ExtendResult?) async -> ExtendResult? {
        if let running = job { return await running.task.value }
        error = nil
        let task = Task { @MainActor () -> ExtendResult? in
            var out: ExtendResult? = nil
            do {
                out = try await body()
            } catch {
                self.error = (error as? ChainError)?.text ?? String(describing: error)
            }
            return out
        }
        job = (kind, task)
        listeners.notify()
        let out = await task.value
        if job?.kind == kind { job = nil; progress = nil; fraction = nil }
        listeners.notify()
        return out
    }

    /// How many blocks a sweep from `cursor` can fetch before it meets ground
    /// already read (or the floor), capped by the budget.
    private func reach(from cursor: UInt64) -> UInt64 {
        let coverage = store.feedCoverage()
        let held = Segments.segment(at: cursor, in: coverage)
        let top: UInt64 = held.map { $0.from > 0 ? $0.from - 1 : 0 } ?? cursor
        let below = Segments.topBelow(top, in: coverage)
        let bottom = below.map { max($0 + 1, floor) } ?? floor
        guard top >= bottom else { return 0 }
        return min(top - bottom + 1, scanBlocks)
    }

    private func sweep(cursor: UInt64, n: Int, floor: UInt64) async throws -> SweepResult {
        let reach = self.reach(from: cursor)
        return try await Scanner.sweepFeed(
            store: store,
            cursor: cursor,
            n: n,
            floor: floor,
            windowSize: windowSize,
            maxBlocks: scanBlocks,
            fetchRange: { from, to in try await self.io.postsInRange(from: from, to: to) },
            onProgress: { p in
                self.progress = p
                self.fraction = reach > 0 ? min(1, Double(p.fetched) / Double(reach)) : 1
                self.listeners.notify()
            }
        )
    }

    private func doRefresh() async throws {
        let head = try await io.blockNumber()
        let top = head > headLag + floor ? head - headLag : floor
        if let known = store.feedScanHead(), top <= known {
            refreshedAt = now()
            return
        }
        _ = try await sweep(cursor: top, n: pageSize, floor: floor)
        // The head is recorded only once the sweep completes: a sweep that
        // failed part-way keeps its coverage but is retried from the head.
        store.setFeedScanHead(Segments.highest(store.feedCoverage()) ?? top)
        refreshedAt = now()
    }

    private func doExtend() async throws -> ExtendResult {
        guard let top = store.feedCoverage().last else {
            try await doRefresh()
            return ExtendResult(fetched: 0, found: 0, reachedFloor: false)
        }
        if top.from <= floor { return ExtendResult(fetched: 0, found: 0, reachedFloor: true) }
        let before = store.coveredPosts().count
        let swept = try await sweep(cursor: top.from - 1, n: pageSize, floor: floor)
        return ExtendResult(fetched: swept.fetched, found: store.coveredPosts().count - before, reachedFloor: swept.reachedFloor)
    }

    private func doGap(from: UInt64, to: UInt64) async throws {
        _ = try await sweep(cursor: to, n: Int.max, floor: from)
    }
}

// MARK: - One author's list on one chain

@MainActor
public final class AuthorListController {
    public struct Snapshot: Sendable {
        public var rows: [PostRow]
        public var job: JobKind?
        public var progress: (block: UInt64, found: Int, target: Int?)?
        /// Index 0 is the author's first post: once it is on the page there
        /// is nothing older to walk to.
        public var hasMore: Bool
        public var error: String?
        public var refreshedAt: Date?
    }

    public let author: String
    public let chainId: Int
    public let store: MemoryScanStore
    public let listeners = Listeners()

    private let io: ChainReadIO
    private let pageSize: Int
    private let rescanDelay: () -> TimeInterval
    private let now: () -> Date

    private var rows: [PostRow]
    private var job: (kind: JobKind, task: Task<Void, Never>)?
    private var progress: (block: UInt64, found: Int, target: Int?)?
    private var error: String?
    private var refreshedAt: Date?

    public init(author: String, store: MemoryScanStore, io: ChainReadIO, pageSize: Int, rescanDelay: @escaping () -> TimeInterval, now: @escaping () -> Date = { Date() }) {
        self.author = author.lowercased()
        self.chainId = store.chainId
        self.store = store
        self.io = io
        self.pageSize = pageSize
        self.rescanDelay = rescanDelay
        self.now = now
        // What an earlier, completed walk left behind — instantly, no I/O.
        if let head = store.authorScanHead(author) {
            rows = store.knownChain(author, from: head)
        } else {
            rows = []
        }
    }

    public var snapshot: Snapshot {
        Snapshot(
            rows: rows,
            job: job?.kind,
            progress: progress,
            hasMore: rows.last.map { $0.index > 0 } ?? false,
            error: error,
            refreshedAt: refreshedAt
        )
    }

    public func ensureFresh() {
        if job != nil { return }
        if let at = refreshedAt, now().timeIntervalSince(at) < rescanDelay() { return }
        Task { await refresh() }
    }

    public func refresh() async {
        await run(.refresh) { try await self.doRefresh() }
    }

    public func loadMore() async {
        await run(.more) { try await self.doMore() }
    }

    public func retry() async {
        error = nil
        await refresh()
    }

    private func run(_ kind: JobKind, _ body: @escaping @MainActor () async throws -> Void) async {
        if let running = job {
            await running.task.value
            return
        }
        error = nil
        let task = Task { @MainActor in
            do {
                try await body()
            } catch {
                self.error = (error as? ChainError)?.text ?? String(describing: error)
            }
        }
        job = (kind, task)
        listeners.notify()
        await task.value
        if job?.kind == kind { job = nil; progress = nil }
        listeners.notify()
    }

    private func doRefresh() async throws {
        let head = try await io.latestBlock(author: author)
        if head == 0 {
            rows = [] // the author has never published on this chain
            refreshedAt = now()
            listeners.notify()
            return
        }
        let known = store.authorScanHead(author)
        if let known = known, head <= known, !rows.isEmpty {
            refreshedAt = now()
            return
        }
        // Walk from the new head until the chain meets what is already on
        // the page: everything mined since the last visit, plus enough of
        // the rest for a full first page.
        try await walk(from: head, target: max(pageSize, rows.count), connectTo: known)
        store.setAuthorScanHead(author, head)
        refreshedAt = now()
    }

    private func doMore() async throws {
        guard let oldest = rows.last, oldest.index > 0 else { return }
        try await walk(from: oldest.block, skipIndex: oldest.index, target: rows.count + pageSize)
    }

    /// Follow the chain from `from` (skipping posts at or above `skipIndex`
    /// in that first block) until the page holds `target` rows — and, when
    /// `connectTo` is given, at least until the walk reaches that block, so
    /// the new rows join the old ones without a hole between them.
    private func walk(from: UInt64, skipIndex: UInt64? = nil, target: Int, connectTo: UInt64? = nil) async throws {
        var block = from
        var skip = skipIndex
        let startCount = rows.count
        let wanted = target - startCount
        while block > 0 {
            let connected = connectTo.map { block <= $0 } ?? true
            if connected && rows.count >= target { break }
            progress = (block, rows.count - startCount, wanted > 0 ? wanted : nil)
            listeners.notify()
            let fetched = try await Scanner.authorRows(store: store, author: author, block: block) { b in
                try await self.io.authorPostsInBlock(author: self.author, block: b)
            }
            if fetched.isEmpty { break }
            let fresh = skip.map { s in fetched.filter { $0.index < s } } ?? fetched
            skip = nil
            if !fresh.isEmpty { merge(fresh) }
            // The chain must strictly descend; anything else would loop forever.
            let next = fetched[fetched.count - 1].prevBlock
            if next >= block { break }
            block = next
        }
    }

    private func merge(_ fresh: [PostRow]) {
        var byIndex: [UInt64: PostRow] = [:]
        for r in rows { byIndex[r.index] = r }
        for r in fresh { byIndex[r.index] = r }
        rows = byIndex.values.sorted(by: PostRow.indexBefore)
        listeners.notify()
    }
}

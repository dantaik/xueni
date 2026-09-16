// Merged.swift — one list over several chains, ordered by time.
//
// Each chain keeps its own scan; these controllers own none of that. They
// read every chain's rows, tag them with their best-known time, merge them
// newest first, and decide WHICH chain to deepen when the page wants more:
// the one sitting at the frontier, the least-read in time.
//
// MergedFeed is the home feed (mergedFeed.js); MergedWalks is an author's
// posts across chains (mergedAuthorList.js) and, with several authors, the
// following feed (followFeed.js) — the same merge over the same kind of walk.

import Foundation

public struct FrontierLeader: Sendable, Equatable {
    public enum State: String, Sendable { case covered, scanning, error, idle }
    public var chainId: Int
    public var author: String?
    public var state: State
    public var error: String?
    public var exact: Bool
}

public struct Frontier: Sendable, Equatable {
    /// Index of the last complete row; -1 when the marker goes above everything.
    public var after: Int
    public var ts: Double
    public var leaders: [FrontierLeader]
}

// MARK: - The clock and the missing times

/// Fills in timestamps on rows that lack them: a few blocks at a time, each
/// block's time read once and handed to the store, which stamps every row
/// in the block. A port of rowTimes.js.
@MainActor
public final class RowTimeResolver {
    private let store: MemoryScanStore
    private let blockTime: (UInt64) async throws -> Int
    private let limit: Int
    private var inFlight = Set<UInt64>()
    private var failed = Set<UInt64>()

    public init(store: MemoryScanStore, limit: Int = 3, blockTime: @escaping (UInt64) async throws -> Int) {
        self.store = store
        self.limit = limit
        self.blockTime = blockTime
    }

    private func missing(_ rows: [PostRow]) -> [UInt64] {
        var out: [UInt64] = []
        for r in rows {
            let b = r.block
            if out.contains(b) || inFlight.contains(b) || failed.contains(b) { continue }
            if store.knownBlockTime(b) != nil { continue }
            out.append(b)
        }
        return out
    }

    public func resolve(_ rows: [PostRow]) {
        for b in missing(rows) {
            if inFlight.count >= limit { break }
            inFlight.insert(b)
            Task { @MainActor in
                do {
                    let ts = try await self.blockTime(b)
                    self.store.rememberBlockTime(b, ts: ts)
                } catch {
                    self.failed.insert(b)
                }
                self.inFlight.remove(b)
                if !self.missing(rows).isEmpty { self.resolve(rows) }
            }
        }
    }

    /// Let failed blocks be tried again (the next refresh).
    public func forget() { failed.removeAll() }
}

/// One chain's part of a merge: its store, its clock, its block times.
public struct ChainSource: Sendable {
    public let chainId: Int
    public let store: MemoryScanStore
    public let clock: @Sendable () async throws -> ChainClock
    public let blockTime: @Sendable (UInt64) async throws -> Int

    public init(chainId: Int, store: MemoryScanStore, clock: @escaping @Sendable () async throws -> ChainClock, blockTime: @escaping @Sendable (UInt64) async throws -> Int) {
        self.chainId = chainId
        self.store = store
        self.clock = clock
        self.blockTime = blockTime
    }
}

// MARK: - The home feed across chains

@MainActor
public final class MergedFeed {
    public struct ChainState: Sendable {
        public var chainId: Int
        public var job: JobKind?
        public var progress: SweepProgress?
        public var fraction: Double?
        public var error: String?
        public var head: UInt64?
        public var coverage: [Segment]
        public var top: Segment?
        public var floor: UInt64
        public var scanBlocks: UInt64
        public var exhausted: Bool
        public var bound: Double
        public var boundExact: Bool
        public var total: Int
        public var refreshedAt: Date?
    }

    public struct Gap: Sendable, Equatable {
        public var chainId: Int
        /// The page row the gap sits under.
        public var after: Int
        public var from: UInt64
        public var to: UInt64
    }

    public struct Note: Sendable, Equatable {
        public var chainId: Int
        public var fetched: UInt64
    }

    public struct Snapshot: Sendable {
        public var rows: [TimedRow]
        public var shown: Int
        public var total: Int
        public var frontier: Frontier?
        public var gaps: [Gap]
        public var done: Bool
        public var job: JobKind?
        public var scanning: Bool
        public var note: Note?
        public var chains: [ChainState]
        public var anyError: Bool
        public var allErrored: Bool
    }

    /// Sweeps one "load earlier posts" may run before it settles.
    private let maxSweepsPerMore = 3

    private struct Entry {
        let source: ChainSource
        let feed: FeedController
        let floor: UInt64
        let resolver: RowTimeResolver
    }

    private let chains: [Entry]
    private let pageSize: Int
    private var shown: Int
    private var job: (kind: JobKind, task: Task<Void, Never>)?
    private var note: Note?
    private var clocks: [Int: ChainClock] = [:]
    private var clockPending: Set<Int> = []
    private var bottomTs: [Int: (block: UInt64, ts: Int)] = [:]
    private var bottomPending: [Int: (block: UInt64, task: Task<Void, Never>)] = [:]

    public let listeners = Listeners()

    public init(chains: [(source: ChainSource, feed: FeedController, floor: UInt64)], pageSize: Int) {
        self.chains = chains.sorted { $0.source.chainId < $1.source.chainId }.map { c in
            Entry(source: c.source, feed: c.feed, floor: c.floor, resolver: RowTimeResolver(store: c.source.store, blockTime: c.source.blockTime))
        }
        self.pageSize = pageSize
        self.shown = pageSize
        for entry in self.chains {
            entry.feed.listeners.add { [weak self] in
                guard let self else { return }
                self.onChainChange(entry)
                self.listeners.notify()
            }
        }
    }

    public var chainIds: [Int] { chains.map { $0.source.chainId } }

    private struct PerChain {
        let entry: Entry
        let snapshot: FeedController.Snapshot
        let rows: [TimedRow]
        let bound: Double
        let boundExact: Bool
    }

    private func perChain() -> [PerChain] {
        chains.map { entry in
            let s = entry.feed.snapshot
            let clock = clocks[entry.source.chainId]
            let rows = Timeline.timeRows(entry.source.store.coveredPosts(), clock: clock)
            let (bound, exact) = self.bound(entry, s, clock)
            return PerChain(entry: entry, snapshot: s, rows: rows, bound: bound, boundExact: exact)
        }
    }

    private func bound(_ entry: Entry, _ s: FeedController.Snapshot, _ clock: ChainClock?) -> (Double, Bool) {
        guard let top = s.top else { return (.infinity, false) }
        if top.from <= entry.floor { return (-.infinity, true) }
        if let bottom = bottomTs[entry.source.chainId], bottom.block == top.from { return (Double(bottom.ts), true) }
        // Until the bottom block's time is read, an estimate stands in; with
        // no clock yet, nothing is claimed complete.
        if let clock = clock { return (Double(clock.estimate(top.from)), false) }
        return (.infinity, false)
    }

    private func merged(_ per: [PerChain]) -> [TimedRow] {
        per.flatMap { $0.rows }.filter { $0.ts != nil }.sorted(by: Timeline.mergedBefore)
    }

    public var snapshot: Snapshot {
        let per = perChain()
        let all = merged(per)
        let rows = Array(all.prefix(shown))
        let total = per.reduce(0) { $0 + $1.rows.count }
        let (tStar, leaderIdx) = Timeline.frontier(of: per.map { $0.bound })

        let frontier: Frontier? = (chains.count == 1 || tStar == -.infinity) ? nil : Frontier(
            after: Timeline.splitAtFrontier(rows, tStar),
            ts: tStar,
            leaders: leaderIdx.map { i in
                let p = per[i]
                let state: FrontierLeader.State = p.snapshot.top != nil ? .covered : p.snapshot.job != nil ? .scanning : p.snapshot.error != nil ? .error : .idle
                return FrontierLeader(chainId: p.entry.source.chainId, author: nil, state: state, error: p.snapshot.error, exact: p.boundExact)
            }
        )

        // A chain's consecutive rows on the page that sit in different
        // covered ranges have unswept blocks between them — marked per chain.
        var gaps: [Gap] = []
        for p in per {
            var prev: (row: TimedRow, i: Int)? = nil
            for (i, r) in rows.enumerated() where r.chainId == p.entry.source.chainId {
                if let prev = prev {
                    let upper = Segments.segment(at: prev.row.block, in: p.snapshot.coverage)
                    let lower = Segments.segment(at: r.block, in: p.snapshot.coverage)
                    if let upper = upper, let lower = lower, upper != lower {
                        gaps.append(Gap(chainId: p.entry.source.chainId, after: prev.i, from: lower.to + 1, to: upper.from - 1))
                    }
                }
                prev = (r, i)
            }
        }
        gaps.sort { $0.after < $1.after }

        let states = per.map { p in
            ChainState(
                chainId: p.entry.source.chainId,
                job: p.snapshot.job,
                progress: p.snapshot.progress,
                fraction: p.snapshot.fraction,
                error: p.snapshot.error,
                head: p.snapshot.head,
                coverage: p.snapshot.coverage,
                top: p.snapshot.top,
                floor: p.snapshot.floor,
                scanBlocks: p.snapshot.scanBlocks,
                exhausted: p.snapshot.exhausted,
                bound: p.bound,
                boundExact: p.boundExact,
                total: p.rows.count,
                refreshedAt: p.snapshot.refreshedAt
            )
        }

        return Snapshot(
            rows: rows,
            shown: shown,
            total: total,
            frontier: frontier,
            gaps: gaps,
            done: per.allSatisfy { $0.snapshot.exhausted } && all.count <= shown,
            job: job?.kind,
            scanning: job != nil || states.contains { $0.job != nil },
            note: note,
            chains: states,
            anyError: states.contains { $0.error != nil },
            allErrored: !states.isEmpty && states.allSatisfy { $0.error != nil }
        )
    }

    // MARK: Jobs

    /// Refresh every chain that is stale; keep clocks and times current.
    public func ensureFresh() {
        for entry in chains { entry.feed.ensureFresh() }
        refreshClocks()
        for entry in chains {
            entry.resolver.forget()
            onChainChange(entry)
        }
    }

    public func refresh() async {
        refreshClocks()
        await withTaskGroup(of: Void.self) { group in
            for entry in chains { group.addTask { @MainActor in await entry.feed.refresh() } }
        }
    }

    public func retry(chainId: Int? = nil) async {
        let wanted = chains.filter { chainId == nil ? $0.feed.snapshot.error != nil : $0.source.chainId == chainId }
        await withTaskGroup(of: Void.self) { group in
            for entry in wanted { group.addTask { @MainActor in await entry.feed.retry() } }
        }
    }

    /// Show another page, deepening the least-read chain until it is complete.
    public func loadMore() async {
        await run(.more) { await self.more() }
    }

    /// Sweep one chain's gap; the page widens by what turns up.
    public func fillGap(_ gap: Gap) async {
        guard let entry = chains.first(where: { $0.source.chainId == gap.chainId }) else { return }
        await run(.gap) {
            let before = entry.source.store.coveredPosts().count
            await entry.feed.fillGap(from: gap.from, to: gap.to)
            self.shown += entry.source.store.coveredPosts().count - before
        }
    }

    private func run(_ kind: JobKind, _ body: @escaping @MainActor () async -> Void) async {
        if let running = job {
            await running.task.value
            return
        }
        let task = Task { @MainActor in await body() }
        job = (kind, task)
        listeners.notify()
        await task.value
        if job?.kind == kind { job = nil }
        listeners.notify()
    }

    private func leader() -> PerChain? {
        var best: PerChain? = nil
        for p in perChain() where p.bound != -.infinity {
            if best == nil || p.bound > best!.bound { best = p }
        }
        return best
    }

    private func completeCount() -> Int {
        let per = perChain()
        let (tStar, _) = Timeline.frontier(of: per.map { $0.bound })
        let all = merged(per)
        return tStar == -.infinity ? all.count : Timeline.countAbove(all, tStar)
    }

    private func more() async {
        note = nil
        let target = shown + pageSize
        shown = target
        listeners.notify()
        var sweeps = 0
        var fetched: UInt64 = 0
        var found = 0
        var last: Entry? = nil
        while completeCount() < target && sweeps < maxSweepsPerMore {
            guard let leader = leader() else { break }
            let swept = await leader.entry.feed.extend()
            await ensureBottomTs(leader.entry, wait: true)
            sweeps += 1
            last = leader.entry
            if let swept = swept {
                fetched += swept.fetched
                found += swept.found
            }
            if leader.entry.feed.snapshot.error != nil { break } // no point hammering a failing node
        }
        if completeCount() < target, let last = last, found == 0, fetched > 0 {
            note = Note(chainId: last.source.chainId, fetched: fetched)
        }
    }

    // MARK: Times

    private func onChainChange(_ entry: Entry) {
        Task { await self.ensureBottomTs(entry, wait: false) }
        let rows = Array(entry.source.store.coveredPosts().prefix(shown + pageSize))
        entry.resolver.resolve(rows)
    }

    private func refreshClocks() {
        for entry in chains {
            let id = entry.source.chainId
            if clockPending.contains(id) { continue }
            clockPending.insert(id)
            Task { @MainActor in
                if let clock = try? await entry.source.clock() {
                    self.clocks[id] = clock
                    self.listeners.notify()
                }
                self.clockPending.remove(id)
            }
        }
    }

    /// Read the exact time of a chain's coverage bottom, once per bottom.
    private func ensureBottomTs(_ entry: Entry, wait: Bool) async {
        guard let top = entry.feed.snapshot.top else { return }
        let block = top.from
        let id = entry.source.chainId
        if let have = bottomTs[id], have.block == block { return }
        if let pending = bottomPending[id], pending.block == block {
            if wait { await pending.task.value }
            return
        }
        let task = Task { @MainActor in
            if let ts = try? await entry.source.blockTime(block) {
                self.bottomTs[id] = (block, ts)
                self.listeners.notify()
            }
        }
        bottomPending[id] = (block, task)
        if wait { await task.value }
        if bottomPending[id]?.block == block { bottomPending[id] = nil }
    }
}

// MARK: - Walks merged by time: one author across chains, or many authors

/// One (author, chain) walk to merge.
public struct WalkSource: Sendable {
    public let source: ChainSource
    public let author: String
    public let list: AuthorListController

    public init(source: ChainSource, author: String, list: AuthorListController) {
        self.source = source
        self.author = author.lowercased()
        self.list = list
    }
}

@MainActor
public final class MergedWalks {
    public struct WalkState: Sendable {
        public var chainId: Int
        public var author: String
        public var job: JobKind?
        public var progress: (block: UInt64, found: Int, target: Int?)?
        public var error: String?
        public var hasMore: Bool
        public var count: Int
        public var bound: Double
        public var refreshedAt: Date?
    }

    public struct Snapshot: Sendable {
        public var rows: [TimedRow]
        public var shown: Int
        public var total: Int
        public var frontier: Frontier?
        public var hasMore: Bool
        /// Authors who have answered and have nothing at all.
        public var silent: [String]
        public var done: Bool
        public var job: JobKind?
        public var scanning: Bool
        public var walks: [WalkState]
        public var anyError: Bool
        public var allErrored: Bool
    }

    /// Walks one "load more" may deepen before it settles for what it found.
    private let maxWalksPerMore = 3

    private struct Entry {
        let walk: WalkSource
        let resolver: RowTimeResolver
    }

    public let authors: [String]
    private let walks: [Entry]
    /// Nil shows every row (an author page); a number pages (the following feed).
    private let pageSize: Int?
    private var shown: Int
    private var job: (kind: JobKind, task: Task<Void, Never>)?
    private var clocks: [Int: ChainClock] = [:]
    private var clockPending: Set<Int> = []
    private var resolvers: [Int: RowTimeResolver] = [:]

    public let listeners = Listeners()

    public init(walks: [WalkSource], pageSize: Int?) {
        self.authors = Array(Set(walks.map { $0.author })).sorted()
        self.pageSize = pageSize
        self.shown = pageSize ?? Int.max
        var entries: [Entry] = []
        var resolvers: [Int: RowTimeResolver] = [:]
        for w in walks.sorted(by: { ($0.source.chainId, $0.author) < ($1.source.chainId, $1.author) }) {
            let resolver = resolvers[w.source.chainId] ?? RowTimeResolver(store: w.source.store, blockTime: w.source.blockTime)
            resolvers[w.source.chainId] = resolver
            entries.append(Entry(walk: w, resolver: resolver))
        }
        self.walks = entries
        self.resolvers = resolvers
        for entry in self.walks {
            entry.walk.list.listeners.add { [weak self] in
                guard let self else { return }
                entry.resolver.resolve(entry.walk.list.snapshot.rows)
                self.listeners.notify()
            }
        }
    }

    public var chainIds: [Int] { Array(Set(walks.map { $0.walk.source.chainId })).sorted() }

    private struct PerWalk {
        let entry: Entry
        let snapshot: AuthorListController.Snapshot
        let rows: [TimedRow]
        let bound: Double
    }

    private func perWalk() -> [PerWalk] {
        walks.map { entry in
            let s = entry.walk.list.snapshot
            let rows = Timeline.timeRows(s.rows, clock: clocks[entry.walk.source.chainId])
            let bound = Timeline.walkBound(hasMore: s.hasMore, running: s.job != nil, failed: s.error != nil, everRefreshed: s.refreshedAt != nil, rows: rows)
            return PerWalk(entry: entry, snapshot: s, rows: rows, bound: bound)
        }
    }

    private func merged(_ per: [PerWalk]) -> [TimedRow] {
        per.flatMap { $0.rows }.filter { $0.ts != nil }.sorted(by: Timeline.mergedBefore)
    }

    public var snapshot: Snapshot {
        let per = perWalk()
        let all = merged(per)
        let rows = Array(all.prefix(shown))
        let (tStar, leaderIdx) = Timeline.frontier(of: per.map { $0.bound })
        let frontier: Frontier? = (per.count <= 1 || tStar == -.infinity) ? nil : Frontier(
            after: Timeline.splitAtFrontier(rows, tStar),
            ts: tStar,
            leaders: leaderIdx.map { i in
                let p = per[i]
                let state: FrontierLeader.State = !p.rows.isEmpty ? .covered : p.snapshot.job != nil ? .scanning : p.snapshot.error != nil ? .error : .idle
                return FrontierLeader(chainId: p.entry.walk.source.chainId, author: p.entry.walk.author, state: state, error: p.snapshot.error, exact: p.rows.last?.exact ?? false)
            }
        )
        let states = per.map { p in
            WalkState(
                chainId: p.entry.walk.source.chainId,
                author: p.entry.walk.author,
                job: p.snapshot.job,
                progress: p.snapshot.progress,
                error: p.snapshot.error,
                hasMore: p.snapshot.hasMore,
                count: p.rows.count,
                bound: p.bound,
                refreshedAt: p.snapshot.refreshedAt
            )
        }
        let silent = authors.filter { author in
            per.filter { $0.entry.walk.author == author }
                .allSatisfy { $0.rows.isEmpty && $0.snapshot.refreshedAt != nil && $0.snapshot.error == nil }
        }
        return Snapshot(
            rows: rows,
            shown: shown,
            total: all.count,
            frontier: frontier,
            hasMore: per.contains { $0.bound != -.infinity },
            silent: silent,
            done: per.allSatisfy { $0.bound == -.infinity } && all.count <= shown,
            job: job?.kind,
            scanning: job != nil || states.contains { $0.job != nil },
            walks: states,
            anyError: states.contains { $0.error != nil },
            allErrored: !states.isEmpty && states.allSatisfy { $0.error != nil }
        )
    }

    public func ensureFresh() {
        for entry in walks { entry.walk.list.ensureFresh() }
        refreshClocks()
        for resolver in resolvers.values { resolver.forget() }
        for entry in walks { entry.resolver.resolve(entry.walk.list.snapshot.rows) }
    }

    public func refresh() async {
        refreshClocks()
        await withTaskGroup(of: Void.self) { group in
            for entry in walks { group.addTask { @MainActor in await entry.walk.list.refresh() } }
        }
    }

    public func retry(chainId: Int? = nil) async {
        let wanted = walks.filter { chainId == nil ? $0.walk.list.snapshot.error != nil : $0.walk.source.chainId == chainId }
        await withTaskGroup(of: Void.self) { group in
            for entry in wanted { group.addTask { @MainActor in await entry.walk.list.retry() } }
        }
    }

    /// Walk the chain sitting at the frontier further — one page of rows
    /// when paging, one walk when not.
    public func loadMore() async {
        await run(.more) {
            if let pageSize = self.pageSize {
                let target = self.shown + pageSize
                self.shown = target
                self.listeners.notify()
                var count = 0
                while self.completeCount() < target && count < self.maxWalksPerMore {
                    guard let leader = self.leader() else { break }
                    if leader.rows.isEmpty { await leader.entry.walk.list.refresh() } else { await leader.entry.walk.list.loadMore() }
                    count += 1
                    if leader.entry.walk.list.snapshot.error != nil { break }
                }
            } else {
                guard let leader = self.leader() else { return }
                if leader.rows.isEmpty { await leader.entry.walk.list.refresh() } else { await leader.entry.walk.list.loadMore() }
            }
        }
    }

    private func leader() -> PerWalk? {
        var best: PerWalk? = nil
        for p in perWalk() where p.bound != -.infinity {
            if best == nil || p.bound > best!.bound { best = p }
        }
        return best
    }

    private func completeCount() -> Int {
        let per = perWalk()
        let (tStar, _) = Timeline.frontier(of: per.map { $0.bound })
        let all = merged(per)
        return tStar == -.infinity ? all.count : Timeline.countAbove(all, tStar)
    }

    private func run(_ kind: JobKind, _ body: @escaping @MainActor () async -> Void) async {
        if let running = job {
            await running.task.value
            return
        }
        let task = Task { @MainActor in await body() }
        job = (kind, task)
        listeners.notify()
        await task.value
        if job?.kind == kind { job = nil }
        listeners.notify()
    }

    private func refreshClocks() {
        for id in chainIds {
            if clockPending.contains(id) { continue }
            guard let entry = walks.first(where: { $0.walk.source.chainId == id }) else { continue }
            clockPending.insert(id)
            Task { @MainActor in
                if let clock = try? await entry.walk.source.clock() {
                    self.clocks[id] = clock
                    self.listeners.notify()
                }
                self.clockPending.remove(id)
            }
        }
    }
}

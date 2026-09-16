// Scanner.swift — how the reader decides what to fetch, with no chain I/O.
//
// Pure orchestration over a scan store (what has already been read) and
// Segments (the range algebra). Every chain call is injected, so the
// traversal rules can be reasoned about — and exercised — on their own.
//
// The rule throughout: a block inside a covered range is answered from the
// store and never re-fetched.

import Foundation

/// What one `eth_getLogs` window came back with, and how far up it really
/// read (a node that hasn't seen the top of the window serves a shorter one).
public struct RangeResult: Sendable {
    public var rows: [PostRow]
    public var to: UInt64?

    public init(rows: [PostRow], to: UInt64? = nil) {
        self.rows = rows
        self.to = to
    }
}

public struct SweepProgress: Sendable, Equatable {
    public enum Phase: Sendable { case fetching, fetched }
    public var phase: Phase
    public var from: UInt64
    public var to: UInt64
    /// Blocks read from the node so far in this sweep.
    public var fetched: UInt64
    public var found: Int
}

public struct SweepResult: Sendable {
    public var rows: [PostRow]
    /// Nothing older is left to read.
    public var reachedFloor: Bool
    public var windows: Int
    /// Blocks read from the node.
    public var fetched: UInt64
}

public enum Scanner {
    /// Never shrink a getLogs window below this — past it, give up instead.
    public static let minWindow: UInt64 = 25

    /// Sweep backwards from `cursor` collecting up to `n` posts, newest
    /// first: `windowSize` blocks per fetch, at most `maxBlocks` fetched
    /// from the node in this call, never below `floor`. Ranges already read
    /// cost nothing, and every window is recorded in the store as soon as
    /// it lands, so a sweep cut short keeps everything it had read.
    @MainActor
    public static func sweepFeed(
        store: MemoryScanStore,
        cursor: UInt64,
        n: Int,
        olderThan: PostRow? = nil,
        floor: UInt64 = 0,
        windowSize: UInt64,
        maxBlocks: UInt64,
        fetchRange: (UInt64, UInt64) async throws -> RangeResult,
        onProgress: ((SweepProgress) -> Void)? = nil
    ) async throws -> SweepResult {
        var span = windowSize
        let budget = maxBlocks
        var out: [PostRow] = []
        var taken = Set<String>()
        let bottom = floor
        var at = cursor
        var windows = 0
        var fetched: UInt64 = 0
        var reachedFloor = false

        func take(_ rows: [PostRow]) -> Bool {
            for row in rows {
                if let cursorRow = olderThan, !row.isOlder(than: cursorRow) { continue }
                if taken.contains(row.postKey) { continue }
                taken.insert(row.postKey)
                out.append(row)
                if out.count >= n { return true }
            }
            return false
        }

        while out.count < n && at >= bottom && fetched < budget {
            if let covered = Segments.segment(at: at, in: store.feedCoverage()) {
                let from = max(covered.from, bottom)
                let held = store.posts(from: from, to: at)
                let full = take(held)
                if from <= bottom {
                    reachedFloor = true
                    break
                }
                at = from - 1
                if full { break }
                continue
            }

            // Never read past the budget: the last window is cut to what is left.
            let width = min(span, budget - fetched)
            let windowStart: UInt64 = at + 1 >= width ? at + 1 - width : 0
            let windowFloor = max(windowStart, bottom)
            let below = Segments.topBelow(at, in: store.feedCoverage())
            let from = below.map { max($0 + 1, windowFloor) } ?? windowFloor
            onProgress?(SweepProgress(phase: .fetching, from: from, to: at, fetched: fetched, found: 0))
            let res: RangeResult
            do {
                res = try await fetchRange(from, at)
            } catch let error as ChainError where error.isRangeTooLarge && span > minWindow {
                // The node caps getLogs ranges below our window. Halve and
                // retry the same window top: coverage is only ever recorded
                // for what was read, so nothing is claimed on the way.
                span = max(span / 2, minWindow)
                continue
            }
            let to = res.to.map { min($0, at) } ?? at
            let rows = store.rememberPosts(res.rows)
            windows += 1
            fetched += to - from + 1
            store.rememberFeedRange(from, to)
            onProgress?(SweepProgress(phase: .fetched, from: from, to: to, fetched: fetched, found: rows.count))
            let full = take(rows.sorted(by: PostRow.feedBefore))
            if from <= bottom {
                reachedFloor = true
                break
            }
            at = from - 1
            if full { break }
        }
        return SweepResult(rows: out, reachedFloor: reachedFloor, windows: windows, fetched: fetched)
    }

    /// Rows for one block of `author`'s chain, newest (highest index)
    /// first. Every block asked for here is one the chain points at — the
    /// author's latestBlock() or a prevBlock — so it holds at least one of
    /// their posts. An empty answer is a node that hasn't caught up, never
    /// the truth: it is not recorded as coverage, and the walk fails so it
    /// can be retried.
    @MainActor
    public static func authorRows(
        store: MemoryScanStore,
        author: String,
        block: UInt64,
        fetchBlock: @escaping @MainActor (UInt64) async throws -> [PostRow]
    ) async throws -> [PostRow] {
        if Segments.segment(at: block, in: store.authorCoverage(author)) != nil {
            let held = store.authorPosts(author, inBlock: block)
            if !held.isEmpty { return held }
        }
        try await store.once("author:\(author.lowercased()):\(block)") {
            // A parallel walk may have read it while we waited our turn.
            if !store.authorPosts(author, inBlock: block).isEmpty { return }
            let rows = try await fetchBlock(block)
            if rows.isEmpty { throw ChainError.nodeBehind(block: block) }
            store.rememberPosts(rows)
            store.rememberAuthorBlock(author, block)
        }
        let rows = store.authorPosts(author, inBlock: block)
        if rows.isEmpty { throw ChainError.nodeBehind(block: block) }
        return rows
    }

    /// Find one (author, index) by walking back from `startBlock`. Nil when
    /// the chain descends past the target without holding it.
    @MainActor
    public static func findAuthorPost(
        store: MemoryScanStore,
        author: String,
        targetIndex: UInt64,
        startBlock: UInt64,
        fetchBlock: @escaping @MainActor (UInt64) async throws -> [PostRow]
    ) async throws -> PostRow? {
        var block = startBlock
        while block > 0 {
            let rows = try await authorRows(store: store, author: author, block: block, fetchBlock: fetchBlock)
            if rows.isEmpty { return nil }
            if let hit = rows.first(where: { $0.index == targetIndex }) { return hit }
            let oldest = rows[rows.count - 1]
            if oldest.index < targetIndex { return nil } // walked past
            let next = oldest.prevBlock
            if next >= block { return nil } // chain doesn't descend — give up
            block = next
        }
        return nil
    }
}

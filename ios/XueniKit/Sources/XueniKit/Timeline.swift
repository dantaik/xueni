// Timeline.swift — the arithmetic of a feed that spans chains.
//
// Block heights order posts within one chain and mean nothing across two,
// so a merged feed orders by time: the exact block timestamp a row carries,
// or an estimate from the chain's clock until it does.
//
// Two ideas, both pure:
//   - timed rows: one chain's rows, newest first, each with its best-known
//     time and whether that time is exact;
//   - the frontier: each chain is completely known from its head down to
//     some time (its `bound`); the merge is complete only above the newest
//     of those bounds, T*. Rows below T* are shown under a marker, and the
//     chains sitting at T* are the ones to deepen.

import Foundation

/// The chain's newest block and how fast blocks have been coming.
public struct ChainClock: Sendable, Equatable {
    public var block: UInt64
    public var ts: Int
    public var secondsPerBlock: Double

    public init(block: UInt64, ts: Int, secondsPerBlock: Double) {
        self.block = block
        self.ts = ts
        self.secondsPerBlock = secondsPerBlock
    }

    /// Estimate when `block` was mined from this clock.
    public func estimate(_ block: UInt64) -> Int {
        let drift = (Double(block) - Double(self.block)) * secondsPerBlock
        return Int((Double(ts) + drift).rounded(.down))
    }
}

/// One row with its chain and its best-known time.
public struct TimedRow: Sendable, Hashable, Identifiable {
    public var row: PostRow
    public var ts: Int?
    public var exact: Bool

    public init(row: PostRow, ts: Int?, exact: Bool) {
        self.row = row
        self.ts = ts
        self.exact = exact
    }

    public var id: String { row.id }
    public var chainId: Int { row.chainId }
    public var block: UInt64 { row.block }
}

public enum Timeline {
    /// Tag one chain's newest-first rows with their best-known time. A row
    /// without a timestamp gets an estimate from `clock` (nil without one),
    /// clamped between the exact times around it so it can neither leap
    /// above a row it was mined behind nor sink below one it preceded.
    public static func timeRows(_ rows: [PostRow], clock: ChainClock?) -> [TimedRow] {
        var out = rows.map { r -> TimedRow in
            if let ts = r.ts { return TimedRow(row: r, ts: ts, exact: true) }
            return TimedRow(row: r, ts: clock?.estimate(r.block), exact: false)
        }
        var floors = [Int](repeating: Int.min, count: out.count)
        var below = Int.min
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            floors[i] = below
            if out[i].exact, let ts = out[i].ts { below = ts }
        }
        var ceiling = Int.max
        for i in 0..<out.count {
            guard let ts = out[i].ts else { continue }
            if !out[i].exact {
                var t = ts
                if t > ceiling { t = ceiling }
                if t < floors[i] { t = floors[i] }
                out[i].ts = t
            }
            ceiling = out[i].ts!
        }
        return out
    }

    /// Newest first across chains: later time first; at the same second
    /// the lower chain id first, then the higher block, then the higher log
    /// index. Rows without any time sort last.
    public static func mergedBefore(_ a: TimedRow, _ b: TimedRow) -> Bool {
        switch (a.ts, b.ts) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?):
            if x != y { return x > y }
            if a.chainId != b.chainId { return a.chainId < b.chainId }
            if a.block != b.block { return a.block > b.block }
            return (a.row.logIndex ?? 0) > (b.row.logIndex ?? 0)
        }
    }

    /// The frontier of a set of per-chain bounds. A bound is the time a
    /// chain is completely known down to: `+infinity` when it has no
    /// coverage yet, `-infinity` when it is read to its floor. Returns T*
    /// and which chains sit at it.
    public static func frontier(of bounds: [Double]) -> (tStar: Double, leaders: [Int]) {
        var tStar = -Double.infinity
        for b in bounds where b > tStar { tStar = b }
        var leaders: [Int] = []
        if tStar != -.infinity {
            for (i, b) in bounds.enumerated() where b == tStar { leaders.append(i) }
        }
        return (tStar, leaders)
    }

    /// Index of the last row at or above the frontier (-1 when none are).
    public static func splitAtFrontier(_ rows: [TimedRow], _ tStar: Double) -> Int {
        var last = -1
        for (i, r) in rows.enumerated() {
            if let ts = r.ts, Double(ts) >= tStar { last = i } else { break }
        }
        return last
    }

    public static func countAbove(_ rows: [TimedRow], _ tStar: Double) -> Int {
        splitAtFrontier(rows, tStar) + 1
    }

    /// How far down in time an author's list on one chain is known: a walk
    /// that has reached the author's first post knows everything
    /// (-infinity); one still holding rows knows down to its oldest; one
    /// that has not answered yet knows nothing (+infinity).
    public static func walkBound(hasMore: Bool, running: Bool, failed: Bool, everRefreshed: Bool, rows: [TimedRow]) -> Double {
        if let last = rows.last {
            if !hasMore { return -.infinity }
            return last.ts.map(Double.init) ?? .infinity
        }
        if running || failed || !everRefreshed { return .infinity }
        return -.infinity // asked, and there is nothing here
    }
}

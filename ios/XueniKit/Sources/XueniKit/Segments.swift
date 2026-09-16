// Segments.swift — sorted, disjoint, inclusive block ranges.
//
// The reader records which block ranges it has already read from the
// chain. A single `[frontier, head]` range could only ever grow downwards
// from the tip; a SET of ranges lets coverage be discontinuous: blocks
// 1–100 read on Monday and 200–300 read on Tuesday are two segments, and a
// read that later sweeps 200 down to 50 fetches only 199–101 — the rest is
// answered from the rows already cached for that segment.

import Foundation

public struct Segment: Sendable, Hashable, Codable {
    public var from: UInt64
    public var to: UInt64

    public init(_ from: UInt64, _ to: UInt64) {
        self.from = from
        self.to = to
    }

    public func contains(_ block: UInt64) -> Bool {
        from <= block && block <= to
    }

    public var count: UInt64 { to - from + 1 }
}

public enum Segments {
    /// Sort and merge overlapping *or touching* ranges; drop the inverted.
    public static func normalize(_ segments: [Segment]) -> [Segment] {
        let list = segments.filter { $0.to >= $0.from }.sorted { a, b in
            a.from == b.from ? a.to <= b.to : a.from < b.from
        }
        var out: [Segment] = []
        for seg in list {
            if let last = out.last, seg.from <= last.to + 1 {
                // `[1,100]` and `[101,200]` describe one uninterrupted stretch.
                if seg.to > last.to { out[out.count - 1].to = seg.to }
                continue
            }
            out.append(seg)
        }
        return out
    }

    /// Coverage plus one more range.
    public static func add(_ segments: [Segment], _ from: UInt64, _ to: UInt64) -> [Segment] {
        normalize(segments + [Segment(from, to)])
    }

    /// The segment containing `block`, or nil.
    public static func segment(at block: UInt64, in segments: [Segment]) -> Segment? {
        segments.first { $0.contains(block) }
    }

    /// The highest covered block strictly below `block`, or nil — where a
    /// downward fetch window must stop so it doesn't re-read covered ground.
    public static func topBelow(_ block: UInt64, in segments: [Segment]) -> UInt64? {
        var best: UInt64? = nil
        for seg in segments where seg.to < block {
            if best == nil || seg.to > best! { best = seg.to }
        }
        return best
    }

    public static func lowest(_ segments: [Segment]) -> UInt64? { segments.first?.from }
    public static func highest(_ segments: [Segment]) -> UInt64? { segments.last?.to }

    /// Drop every claim below `floor`.
    public static func clipBelow(_ segments: [Segment], _ floor: UInt64) -> [Segment] {
        segments.compactMap { seg in
            if seg.to < floor { return nil }
            return Segment(max(seg.from, floor), seg.to)
        }
    }

    /// Total number of blocks covered.
    public static func blockCount(_ segments: [Segment]) -> UInt64 {
        segments.reduce(0) { $0 + $1.count }
    }
}

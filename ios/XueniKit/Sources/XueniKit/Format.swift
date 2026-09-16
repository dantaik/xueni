// Format.swift — pure presentation helpers.
//
// Deterministic string math shared by every list and page. Block numbers
// stay the on-chain source of truth; a time is exact when the row carries
// its block's timestamp and an estimate until then.

import Foundation

public enum Format {
    /// THE one address form: `0x0000....0000` — `0x` + first 4 hex + `....`
    /// + last 4 hex. Short input is returned as-is.
    public static func shortAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return String(address.prefix(6)) + "...." + String(address.suffix(4))
    }

    /// `0x1234…abcd`, the explorer's own habit, for hashes.
    public static func shortHash(_ hash: String) -> String {
        guard hash.count > 10 else { return hash }
        return String(hash.prefix(6)) + "…" + String(hash.suffix(4))
    }

    /// A byte count, in the unit that reads easiest: `999 B`, `41.9 KB`.
    /// Rounded half away from zero, as `toFixed` does on the web.
    public static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(grouped(n)) B" }
        if n < 1024 * 1024 { return "\(fixed(Double(n) / 1024, places: 1)) KB" }
        return "\(fixed(Double(n) / (1024 * 1024), places: 2)) MB"
    }

    static func fixed(_ value: Double, places: Int) -> String {
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        return String(format: "%.\(places)f", rounded)
    }

    /// `22540123` → `22,540,123` (comma grouping regardless of locale).
    public static func grouped(_ n: UInt64) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }

    public static func grouped(_ n: Int) -> String {
        n < 0 ? "-" + grouped(UInt64(-n)) : grouped(UInt64(n))
    }

    /// 0-based on-chain index → 1-based ordinal.
    public static func ordinal(_ index: UInt64) -> Int {
        Int(index) + 1
    }

    /// The kind of failure a node message describes, as a key for the interface.
    public static func errorKey(_ message: String) -> (key: String, block: String?) {
        let m = message
        if m.hasPrefix("xueni:node-behind ") { return ("error.nodeBehind", String(m.dropFirst("xueni:node-behind ".count))) }
        let lower = m.lowercased()
        if lower.contains("rate limit") || lower.contains("429") || lower.contains("too many requests") { return ("error.rateLimit", nil) }
        if lower.contains("archive") || lower.contains("token") || lower.contains("personal") { return ("error.unsupported", nil) }
        if lower.contains("can't route") || lower.contains("suitable provider") || lower.contains("no provider") { return ("error.unavailable", nil) }
        if lower.contains("network") || lower.contains("fetch") || lower.contains("econn") || lower.contains("refused") || lower.contains("failed") || lower.contains("offline") || lower.contains("timed out") { return ("error.network", nil) }
        return ("error.generic", nil)
    }
}

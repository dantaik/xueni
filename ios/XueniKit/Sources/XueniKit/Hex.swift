// Hex.swift — bytes as the chain writes them: `0x`-prefixed, lowercase.
//
// Every quantity and every blob a node hands back is hex text, and every
// argument it takes is hex text. This is the one place that conversion
// lives, so that a malformed string is refused here rather than misread
// somewhere deeper.

import Foundation

public enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    /// `0x` + lowercase hex of `bytes`.
    public static func string(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2 + 2)
        out.append(UInt8(ascii: "0"))
        out.append(UInt8(ascii: "x"))
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The bytes a hex string names, with or without `0x`; nil for anything
    /// that is not an even run of hex digits (the empty string is `[]`).
    public static func bytes(_ hex: String) -> [UInt8]? {
        var scalars = Substring(hex)
        if scalars.hasPrefix("0x") || scalars.hasPrefix("0X") { scalars = scalars.dropFirst(2) }
        let utf8 = Array(scalars.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// A JSON-RPC quantity: `0x` + the shortest hex, `0x0` for zero.
    public static func quantity(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// A JSON-RPC quantity read back; nil when it is not one, or does not
    /// fit 64 bits (no block height, index or timestamp ever will).
    public static func parseQuantity(_ hex: String) -> UInt64? {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        guard !s.isEmpty, s.count <= 16 else { return nil }
        return UInt64(s, radix: 16)
    }

    /// Is this a 20-byte address, in either case?
    public static func isAddress(_ s: String) -> Bool {
        isHexRun(s, digits: 40)
    }

    /// Is this a 32-byte hash, in either case?
    public static func isHash(_ s: String) -> Bool {
        isHexRun(s, digits: 64)
    }

    private static func isHexRun(_ s: String, digits: Int) -> Bool {
        let utf8 = Array(s.utf8)
        guard utf8.count == digits + 2, utf8[0] == UInt8(ascii: "0"), utf8[1] == UInt8(ascii: "x") || utf8[1] == UInt8(ascii: "X") else {
            return false
        }
        for c in utf8[2...] where nibble(c) == nil { return false }
        return true
    }

    /// The one spelling of an address or hash used as a key: lowercase.
    public static func lower(_ s: String) -> String {
        s.lowercased()
    }
}

// Identicon.swift — the blockies square, in grey.
//
// Every wallet is its own author here, and the addresses are unrelated to
// each other, so the eye needs something it can tell apart at a glance in a
// list. The web app draws the blockies identicon through `blo`; this is the
// same arithmetic — the same seed, the same 8×8 pattern every wallet draws
// for an address — so a face here is the face there. What differs is the
// paint: the interface is black, white and grey, so the three colours
// become three tones, chosen from the lightness each colour would have had.

import Foundation

public struct Identicon: Sendable, Equatable {
    public static let size = 8

    /// Row-major, `size × size`: 0 background, 1 colour, 2 spot.
    public let cells: [UInt8]
    /// Tones in 0…1 (0 black, 1 white).
    public let background: Double
    public let color: Double
    public let spot: Double

    public static func make(for address: String) -> Identicon {
        var rng = SeededRandom(seed: address.lowercased())
        let c = rng.color()
        let b = rng.color()
        let s = rng.color()
        var half = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            // background 43%, colour 43%, spot 13%; anything past 2 is background.
            let v = Int((rng.next() * 2.3).rounded(.down))
            half[i] = v == 1 ? 1 : v == 2 ? 2 : 0
        }
        var cells = [UInt8](repeating: 0, count: size * size)
        for i in 0..<32 {
            let x = i & 3
            let y = i >> 2
            cells[y * size + x] = half[i]
            cells[y * size + (7 - x)] = half[i]
        }
        let tones = Identicon.tones(background: b.lightness, color: c.lightness, spot: s.lightness)
        return Identicon(cells: cells, background: tones.0, color: tones.1, spot: tones.2)
    }

    /// Lightness alone can put two colours a hair apart; the tones are
    /// pushed apart until the pattern reads, keeping the darker one darker.
    static func tones(background: Double, color: Double, spot: Double) -> (Double, Double, Double) {
        let bg = background
        var fg = color
        if abs(fg - bg) < 0.35 {
            fg = bg >= 0.5 ? max(0, bg - 0.45) : min(1, bg + 0.45)
        }
        var sp = spot
        if abs(sp - bg) < 0.25 || abs(sp - fg) < 0.2 {
            sp = (bg + fg) / 2 + (bg > fg ? 0.25 : -0.25)
            sp = min(1, max(0, sp))
        }
        return (bg, fg, sp)
    }

    public func cell(x: Int, y: Int) -> UInt8 {
        cells[y * Identicon.size + x]
    }
}

/// blo's PRNG, with JavaScript's Uint32Array and int32 semantics kept.
struct SeededRandom {
    struct HSL {
        let hue: Int
        let saturation: Int
        /// 0…1, the CSS `hsl()` lightness clamped as a browser clamps it.
        let lightness: Double
    }

    private var seed: [UInt32] = [0, 0, 0, 0]

    init(seed text: String) {
        for (i, unit) in text.utf16.enumerated() {
            let k = i % 4
            let current = seed[k]
            let shifted = Int32(bitPattern: current) &<< 5
            let value = Int64(shifted) - Int64(current) + Int64(unit)
            seed[k] = UInt32(truncatingIfNeeded: value)
        }
    }

    /// In 0…2, as `rseed[3] * (1 / 2^31)` over an unsigned 32-bit word.
    mutating func next() -> Double {
        let r0 = Int32(bitPattern: seed[0])
        let t = r0 ^ (r0 &<< 11)
        seed[0] = seed[1]
        seed[1] = seed[2]
        seed[2] = seed[3]
        let r3 = Int32(bitPattern: seed[3])
        let n = r3 ^ (r3 >> 19) ^ t ^ (t >> 8)
        seed[3] = UInt32(bitPattern: n)
        return Double(seed[3]) / 2_147_483_648.0
    }

    mutating func color() -> HSL {
        let h = Int(next() * 360)
        let s = Int(40 + next() * 60)
        let l = Int((next() + next() + next() + next()) * 25)
        return HSL(hue: h, saturation: s, lightness: Double(min(l, 100)) / 100)
    }
}

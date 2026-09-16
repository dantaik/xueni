// Keccak.swift — Keccak-256, the hash Ethereum names everything by.
//
// The reader needs it for exactly one thing: ENS name hashes (ENS.swift).
// Every other hash the app touches — the Post event topic, the function
// selectors — is a constant pinned in ABI.swift and checked against this
// implementation by the tests, so the two cannot drift apart.
//
// This is the plain permutation of FIPS 202 with the original Keccak
// padding (0x01 … 0x80), which is what Ethereum uses; SHA3-256 differs only
// in that padding byte.

import Foundation

public enum Keccak {
    private static let rate = 136 // bytes absorbed per permutation for a 256-bit digest

    /// The 32-byte Keccak-256 digest of `data`.
    public static func hash256(_ data: [UInt8]) -> [UInt8] {
        var state = [UInt64](repeating: 0, count: 25)
        var offset = 0
        while data.count - offset >= rate {
            absorb(&state, data, from: offset)
            offset += rate
        }
        var last = [UInt8](repeating: 0, count: rate)
        let tail = data.count - offset
        for i in 0..<tail { last[i] = data[offset + i] }
        last[tail] ^= 0x01
        last[rate - 1] ^= 0x80
        absorb(&state, last, from: 0)

        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in 0..<4 {
            var v = state[word]
            for _ in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: v))
                v >>= 8
            }
        }
        return out
    }

    /// Keccak-256 of a string's UTF-8 bytes.
    public static func hash256(_ text: String) -> [UInt8] {
        hash256(Array(text.utf8))
    }

    private static func absorb(_ state: inout [UInt64], _ block: [UInt8], from offset: Int) {
        for word in 0..<(rate / 8) {
            var v: UInt64 = 0
            for b in 0..<8 {
                v |= UInt64(block[offset + word * 8 + b]) << UInt64(8 * b)
            }
            state[word] ^= v
        }
        permute(&state)
    }

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808a, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808b, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008a, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000a,
        0x0000_0000_8000_808b, 0x8000_0000_0000_008b, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800a, 0x8000_0000_8000_000a,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]
    private static let rotations: [Int] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let piLanes: [Int] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]

    @inline(__always)
    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << UInt64(n)) | (x >> UInt64(64 - n))
    }

    private static func permute(_ st: inout [UInt64]) {
        var bc = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // θ
            for i in 0..<5 { bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20] }
            for i in 0..<5 {
                let t = bc[(i + 4) % 5] ^ rotl(bc[(i + 1) % 5], 1)
                var j = 0
                while j < 25 {
                    st[j + i] ^= t
                    j += 5
                }
            }
            // ρ and π
            var t = st[1]
            for i in 0..<24 {
                let j = piLanes[i]
                let tmp = st[j]
                st[j] = rotl(t, rotations[i])
                t = tmp
            }
            // χ
            var j = 0
            while j < 25 {
                for i in 0..<5 { bc[i] = st[j + i] }
                for i in 0..<5 { st[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5] }
                j += 5
            }
            // ι
            st[0] ^= roundConstants[round]
        }
    }
}

// ABI.swift — the contract surface the reader touches, by hand.
//
// Two view calls, one event, three publishing calls: small enough that a
// general ABI encoder would be more code than the encodings themselves.
// Every constant here is the keccak of a signature, and the tests recompute
// each one with Keccak.swift so a typo cannot survive.

import Foundation

public enum ABI {
    /// `keccak256("Post(address,address,uint256,uint256,bytes32)")` — topic 0
    /// of every post on the contract.
    public static let postEventTopic = "0xb9b1202ea7165d7724de1f5fd6ae97b9a1b4376c87e1fdbcceb4907f60a78a9d"

    public static let latestBlockSelector: [UInt8] = [0xf9, 0xa2, 0x95, 0x1d] // latestBlock(address)
    public static let countSelector: [UInt8] = [0x05, 0xd8, 0x5e, 0xda] // count(address)

    public static let publishSelector: [UInt8] = [0x70, 0xa7, 0x45, 0x32] // publish(bytes32,bytes)
    public static let publishWithHookSelector: [UInt8] = [0xcf, 0x5f, 0x0b, 0xff] // publish(bytes32,bytes,address,bytes)
    public static let publishForSelector: [UInt8] = [0x80, 0xe4, 0x1e, 0x43] // publishFor(address,bytes32,bytes,address,bytes,uint256,bytes)

    public static let zeroAddress = "0x0000000000000000000000000000000000000000"

    // MARK: - Words

    /// A 32-byte word holding an address, right-aligned behind twelve zeros.
    public static func addressWord(_ address: String) -> [UInt8]? {
        guard Hex.isAddress(address), let bytes = Hex.bytes(address) else { return nil }
        return [UInt8](repeating: 0, count: 12) + bytes
    }

    /// A 32-byte word holding a small unsigned integer, big-endian.
    public static func uintWord(_ value: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 24)
        var v = value
        var tail = [UInt8](repeating: 0, count: 8)
        for i in stride(from: 7, through: 0, by: -1) {
            tail[i] = UInt8(truncatingIfNeeded: v)
            v >>= 8
        }
        out.append(contentsOf: tail)
        return out
    }

    /// The unsigned integer a word holds, when it fits 64 bits.
    public static func uint64(word: ArraySlice<UInt8>) -> UInt64? {
        guard word.count == 32 else { return nil }
        let bytes = Array(word)
        for i in 0..<24 where bytes[i] != 0 { return nil }
        var v: UInt64 = 0
        for i in 24..<32 { v = v << 8 | UInt64(bytes[i]) }
        return v
    }

    /// The address a word holds, lowercase, or nil when its upper twelve
    /// bytes are not zero — the contract's own decoder refuses such a word.
    public static func address(word: ArraySlice<UInt8>) -> String? {
        guard word.count == 32 else { return nil }
        let bytes = Array(word)
        for i in 0..<12 where bytes[i] != 0 { return nil }
        return Hex.string(Array(bytes[12..<32]))
    }

    /// The address a topic holds (the same layout as a word).
    public static func address(topic: String) -> String? {
        guard let bytes = Hex.bytes(topic), bytes.count == 32 else { return nil }
        return address(word: bytes[0..<32])
    }

    // MARK: - Calls

    /// `latestBlock(author)` as calldata.
    public static func latestBlockCall(_ author: String) -> String? {
        guard let word = addressWord(author) else { return nil }
        return Hex.string(latestBlockSelector + word)
    }

    /// `count(author)` as calldata.
    public static func countCall(_ author: String) -> String? {
        guard let word = addressWord(author) else { return nil }
        return Hex.string(countSelector + word)
    }

    // MARK: - The Post event

    /// What one `Post` log says, before it is tied to a block or a transaction.
    public struct PostEvent: Sendable, Equatable {
        public let author: String
        /// The hook the post went through, lowercase, or nil for a plain post.
        public let hook: String?
        public let index: UInt64
        public let prevBlock: UInt64
        /// The title, decoded per the codec's §3.1.
        public let title: String
    }

    /// Decode a `Post` log's topics and data. Nil when it is some other
    /// event, or is malformed.
    public static func decodePostEvent(topics: [String], data: String) -> PostEvent? {
        guard topics.count == 3, topics[0].lowercased() == postEventTopic else { return nil }
        guard let author = address(topic: topics[1]), let hook = address(topic: topics[2]) else { return nil }
        guard let bytes = Hex.bytes(data), bytes.count >= 96 else { return nil }
        guard let index = uint64(word: bytes[0..<32]), let prev = uint64(word: bytes[32..<64]) else { return nil }
        let title = Title.decode(Array(bytes[64..<96]))
        return PostEvent(author: author, hook: hook == zeroAddress ? nil : hook, index: index, prevBlock: prev, title: title)
    }
}

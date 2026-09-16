// ENS.swift — the identity layer the contract deliberately has not got.
//
// Xueni knows only addresses. ENS is the answer already on chain: a
// registry with no owner, on the same L1, read with the same client. A
// reverse record is a CLAIM the address makes about itself, so a reversed
// name is resolved forward again and trusted only when it comes back to
// the same address. Everything here is best effort: a lookup that fails
// leaves the address showing, and nothing waits on it.
//
// Only Ethereum mainnet hosts ENS, so the app hands this the mainnet
// reader whatever chain a post is on.

import Foundation

public enum ENS {
    /// The ENS registry, the same on mainnet since 2019.
    public static let registry = "0x00000000000c2e074ec69a0dfb2997ba6c7d2e1e"

    private static let resolverSelector: [UInt8] = [0x01, 0x78, 0xb8, 0xbf] // resolver(bytes32)
    private static let nameSelector: [UInt8] = [0x69, 0x1f, 0x34, 0x31] // name(bytes32)
    private static let addrSelector: [UInt8] = [0x3b, 0x3b, 0x57, 0xde] // addr(bytes32)
    private static let textSelector: [UInt8] = [0x59, 0xd1, 0xd4, 0x3c] // text(bytes32,string)

    /// Does this look like an ENS name? Deliberately narrow — `.eth` only.
    public static func isName(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasSuffix(".eth"), s.count > 4 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
        }
    }

    /// A name as it is hashed: lowercase and NFC. Not the whole of
    /// ENSIP-15, which needs tables this app does not carry; the names it
    /// misses are the ones no reader types.
    public static func normalize(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.hasSuffix("."), !trimmed.contains("..") else { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 }) { return nil }
        return trimmed
    }

    /// EIP-137 namehash.
    public static func namehash(_ name: String) -> [UInt8] {
        var node = [UInt8](repeating: 0, count: 32)
        guard !name.isEmpty else { return node }
        for label in name.split(separator: ".", omittingEmptySubsequences: false).reversed() {
            node = Keccak.hash256(node + Keccak.hash256(String(label)))
        }
        return node
    }

    /// The reverse node of an address: `<hex>.addr.reverse`.
    public static func reverseNode(_ address: String) -> [UInt8] {
        let hex = address.lowercased().hasPrefix("0x") ? String(address.lowercased().dropFirst(2)) : address.lowercased()
        return namehash("\(hex).addr.reverse")
    }

    // MARK: - Calls

    static func resolverCall(_ node: [UInt8]) -> [UInt8] { resolverSelector + node }
    static func nameCall(_ node: [UInt8]) -> [UInt8] { nameSelector + node }
    static func addrCall(_ node: [UInt8]) -> [UInt8] { addrSelector + node }

    static func textCall(_ node: [UInt8], key: String) -> [UInt8] {
        let bytes = Array(key.utf8)
        let padded = bytes + [UInt8](repeating: 0, count: (32 - bytes.count % 32) % 32)
        return textSelector + node + ABI.uintWord(64) + ABI.uintWord(UInt64(bytes.count)) + padded
    }

    /// An ABI-encoded `string` return value.
    static func decodeString(_ out: [UInt8]) -> String? {
        guard out.count >= 64, let offset = ABI.uint64(word: out[0..<32]), Int(offset) + 32 <= out.count else { return nil }
        let at = Int(offset)
        guard let length = ABI.uint64(word: out[at..<(at + 32)]), at + 32 + Int(length) <= out.count else { return nil }
        return String(decoding: out[(at + 32)..<(at + 32 + Int(length))], as: UTF8.self)
    }

    static func decodeAddress(_ out: [UInt8]) -> String? {
        guard out.count >= 32, let address = ABI.address(word: out[0..<32]), address != ABI.zeroAddress else { return nil }
        return address
    }
}

/// ENS lookups over one mainnet reader, cached for a while.
public final class ENSResolver: @unchecked Sendable {
    public static let ttl: TimeInterval = 10 * 60

    private let io: ChainIO
    private let cache = TTLCache<String>()

    public init(io: ChainIO) {
        self.io = io
    }

    private func resolver(for node: [UInt8]) async throws -> String? {
        let out = try await io.call(to: ENS.registry, data: ENS.resolverCall(node))
        return ENS.decodeAddress(out)
    }

    /// The address a name points at, or nil when it points nowhere.
    public func address(for name: String) async -> String? {
        guard let normalized = ENS.normalize(name), ENS.isName(normalized) else { return nil }
        return await cache.get("addr:\(normalized)", ttl: Self.ttl) {
            let node = ENS.namehash(normalized)
            guard let resolver = try? await self.resolver(for: node) else { return nil }
            guard let out = try? await self.io.call(to: resolver, data: ENS.addrCall(node)) else { return nil }
            return ENS.decodeAddress(out)
        }
    }

    /// The name an address has claimed AND which claims it back, or nil.
    public func name(for address: String) async -> String? {
        let who = address.lowercased()
        guard Hex.isAddress(who) else { return nil }
        return await cache.get("name:\(who)", ttl: Self.ttl) {
            let node = ENS.reverseNode(who)
            guard let resolver = try? await self.resolver(for: node) else { return nil }
            guard let out = try? await self.io.call(to: resolver, data: ENS.nameCall(node)) else { return nil }
            guard let claimed = ENS.decodeString(out), !claimed.isEmpty else { return nil }
            guard let forward = await self.address(for: claimed), forward == who else { return nil }
            return ENS.normalize(claimed)
        }
    }

    /// One text record of a name (`description`, `url`, `com.github`…), or nil.
    public func text(_ name: String, key: String) async -> String? {
        guard let normalized = ENS.normalize(name) else { return nil }
        return await cache.get("text:\(normalized):\(key)", ttl: Self.ttl) {
            let node = ENS.namehash(normalized)
            guard let resolver = try? await self.resolver(for: node) else { return nil }
            guard let out = try? await self.io.call(to: resolver, data: ENS.textCall(node, key: key)) else { return nil }
            guard let value = ENS.decodeString(out), !value.isEmpty else { return nil }
            return value
        }
    }
}

/// A small cache of optional answers with a lifetime; concurrent asks for
/// the same key share one lookup.
actor TTLCache<Value: Sendable> {
    private struct Entry {
        let at: Date
        let task: Task<Value?, Never>
    }
    private var entries: [String: Entry] = [:]

    func get(_ key: String, ttl: TimeInterval, _ compute: @escaping @Sendable () async -> Value?) async -> Value? {
        if let hit = entries[key], Date().timeIntervalSince(hit.at) < ttl {
            return await hit.task.value
        }
        let task = Task { await compute() }
        entries[key] = Entry(at: Date(), task: task)
        return await task.value
    }

    func clear() {
        entries.removeAll()
    }
}

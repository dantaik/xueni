// Chains.swift — the chains Xueni is deployed on, and how to reach them.
//
// The same registry as webapp/src/lib/chains.js: the contract is
// CREATE2-deployed to ONE address on every EVM chain, so a chain is fully
// described by its id, its explorer, an ordered list of RPC endpoints and
// the block it was deployed in. The endpoint list is ordered — the reader
// tries the first and falls back to the next when one fails — and the
// deployment block is a floor no sweep ever reads below.

import Foundation

public struct Chain: Sendable, Hashable, Identifiable {
    public let id: Int
    /// The proper noun a mainnet is shown under; the same in every language.
    public let name: String
    /// The segment a chain takes in a URL: `/taiko/tx/0x…`.
    public let slug: String
    public let explorer: String
    /// Default RPC endpoints, in preference order.
    public let defaultRPCs: [String]
    /// Blocks per `eth_getLogs` window; under every public node's ceiling.
    public let logWindow: UInt64
    /// The most blocks one scan (one open of the feed, one "load earlier")
    /// reads from the node. Blocks already read are free and do not count.
    public let scanBlocks: UInt64
    /// The block the contract was deployed in; nothing below can hold a post.
    public let deployBlock: UInt64
    /// Only Ethereum mainnet hosts ENS; every other chain is never asked.
    public let hasENS: Bool

    public var explorerURL: URL { URL(string: explorer)! }

    public func txURL(_ txHash: String) -> URL { URL(string: "\(explorer)/tx/\(txHash)")! }
    public func addressURL(_ address: String) -> URL { URL(string: "\(explorer)/address/\(address)")! }
}

public enum Chains {
    /// Xueni.sol at its CREATE2 address — identical on every chain.
    public static let xueniAddress = "0x0000003ce1a46c7fbb02b9e1a0a4709ad9cb15d9"
    /// The fan-out hook deployed beside it (contracts/src/hooks/MultiHook.sol).
    public static let multiHookAddress = "0x0000098b1f5b2fb1f7251af47f8df15eb319ed10"

    public static let ethereum = Chain(
        id: 1,
        name: "Ethereum",
        slug: "ethereum",
        explorer: "https://etherscan.io",
        defaultRPCs: ["https://eth.drpc.org", "https://rpc.mevblocker.io"],
        logWindow: 9_000,
        scanBlocks: 270_000,
        deployBlock: 25_980_697,
        hasENS: true
    )

    public static let taiko = Chain(
        id: 167_000,
        name: "Taiko",
        slug: "taiko",
        explorer: "https://taikoscan.io",
        defaultRPCs: ["https://rpc.mainnet.taiko.xyz", "https://taiko.drpc.org"],
        logWindow: 9_000,
        scanBlocks: 270_000,
        deployBlock: 11_413_668,
        hasENS: false
    )

    /// The chains read together: the feed merges them, the settings list them.
    public static let all: [Chain] = [ethereum, taiko]

    public static func chain(id: Int) -> Chain? {
        all.first { $0.id == id }
    }

    public static func chain(slug: String) -> Chain? {
        let wanted = slug.lowercased()
        if let byName = all.first(where: { $0.slug == wanted }) { return byName }
        if let id = Int(wanted) { return chain(id: id) }
        return nil
    }

    public static func isKnown(_ id: Int) -> Bool {
        chain(id: id) != nil
    }

    /// The name a chain is shown under, or a generic label for one we don't know.
    public static func name(of id: Int) -> String {
        chain(id: id)?.name ?? "Chain \(id)"
    }

    /// Whether `address` is the contract this build reads.
    public static func isContract(_ address: String) -> Bool {
        address.lowercased() == xueniAddress
    }

    /// The name a hook is known by, or nil for a stranger's contract.
    public static func knownHookKey(_ address: String) -> String? {
        address.lowercased() == multiHookAddress ? "multi" : nil
    }
}

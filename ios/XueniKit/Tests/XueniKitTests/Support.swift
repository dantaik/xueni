// Support.swift — what the tests share: the spec's vectors, a brotli that
// knows only them, and an in-memory chain the real reader runs on top of.

import Foundation
import XCTest
@testable import XueniKit

struct Vector: Decodable {
    struct Post: Decodable {
        let title: String
        let tags: [String]
        let markdown: String
        let meta: [String: String]
    }
    struct Relayed: Decodable {
        let author: String
        let deadline: String
        let signature: String
    }
    struct Call: Decodable {
        let hook: String?
        let hookData: String?
        let relayed: Relayed?
    }
    let name: String
    let post: Post
    let call: Call?
    let title: String
    let text: String
    let compressedBytes: Int
    let callData: String
}

struct VectorFile: Decodable {
    let format: Int
    let vectors: [Vector]
    let selectors: [String: String]
}

enum Vectors {
    static let file: VectorFile = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Resources")!
        return try! JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }()

    static var all: [Vector] { file.vectors }
}

/// A "decompressor" that knows the payload bytes of every vector and the
/// document each decompresses to — so the reading rules are checked on a
/// machine with no brotli at all. Where Apple's Compression framework
/// exists, the real decoder is tested against the same vectors.
struct VectorBrotli: BrotliDecompressor {
    static let table: [String: String] = {
        var out: [String: String] = [:]
        for v in Vectors.all {
            let call = try! Codec.decodeCallData(hex: v.callData)
            out[Hex.string(call.payload)] = v.text
        }
        return out
    }()

    /// Pretend bombs: a payload beginning with 0xBB expands to this many bytes.
    var bombBytes: Int? = nil

    func decompress(_ input: [UInt8], maxOutputBytes: Int) throws -> [UInt8] {
        if input.first == 0xBB, let n = bombBytes {
            if n > maxOutputBytes { throw PayloadError.documentTooLarge(bound: maxOutputBytes) }
            return [UInt8](repeating: 0x20, count: n)
        }
        guard let text = Self.table[Hex.string(input)] else { throw PayloadError.malformedPayload("unknown to the table") }
        return Array(text.utf8)
    }
}

/// An in-memory chain: posts placed in blocks, the contract's two views
/// answered from them, and a log of every read, so a test can say how many
/// requests a page cost.
@MainActor
final class FakeChain: ChainReadIO, @unchecked Sendable {
    let chainId: Int
    var head: UInt64
    var posts: [PostRow] = []
    var secondsPerBlock = 12
    var genesisTs = 1_700_000_000
    var rangeLimit: UInt64? = nil
    var failLatestBlock = false
    var log: [String] = []
    var hideBlock: UInt64? = nil

    init(chainId: Int, head: UInt64) {
        self.chainId = chainId
        self.head = head
    }

    func timestamp(_ block: UInt64) -> Int { genesisTs + Int(block) * secondsPerBlock }

    /// Add one post for `author`; prevBlock and index follow from what they have.
    @discardableResult
    func publish(_ author: String, at block: UInt64, title: String, txHash: String? = nil, hook: String? = nil) -> PostRow {
        let mine = posts.filter { $0.author == author.lowercased() }.sorted(by: PostRow.indexBefore)
        let index = mine.first.map { $0.index + 1 } ?? 0
        let prev = mine.first?.block ?? 0
        let hash = txHash ?? "0x" + String(format: "%064x", posts.count + 1)
        let row = PostRow(chainId: chainId, author: author, index: index, block: block, prevBlock: prev, title: title, txHash: hash, eventIndex: 0, logIndex: posts.filter { $0.block == block }.count, ts: timestamp(block), hook: hook)
        posts.append(row)
        if block > head { head = block }
        return row
    }

    func blockNumber() async throws -> UInt64 {
        log.append("eth_blockNumber")
        return head
    }

    func blockTime(_ block: UInt64) async throws -> Int {
        log.append("eth_getBlockByNumber \(block)")
        return timestamp(block)
    }

    func postsInRange(from: UInt64, to: UInt64) async throws -> RangeResult {
        log.append("eth_getLogs \(from)-\(to)")
        if let limit = rangeLimit, to - from + 1 > limit {
            throw ChainError.rpc(code: -32000, message: "query returned more than \(limit) results; block range too large")
        }
        let rows = posts.filter { $0.block >= from && $0.block <= to && $0.block != hideBlock }
        return RangeResult(rows: rows, to: to)
    }

    func authorPostsInBlock(author: String, block: UInt64) async throws -> [PostRow] {
        log.append("eth_getLogs \(block) \(Format.shortAddress(author))")
        if block == hideBlock { return [] }
        return posts.filter { $0.author == author.lowercased() && $0.block == block }.sorted(by: PostRow.indexBefore)
    }

    func latestBlock(author: String) async throws -> UInt64 {
        log.append("latestBlock \(Format.shortAddress(author))")
        if failLatestBlock { throw ChainError.network("connection refused") }
        return posts.filter { $0.author == author.lowercased() }.map { $0.block }.max() ?? 0
    }

    func count(author: String) async throws -> UInt64 {
        UInt64(posts.filter { $0.author == author.lowercased() }.count)
    }

    func clock() -> ChainClock {
        ChainClock(block: head, ts: timestamp(head), secondsPerBlock: Double(secondsPerBlock))
    }

    func source(store: MemoryScanStore) -> ChainSource {
        ChainSource(chainId: chainId, store: store, clock: { await self.clock() }, blockTime: { b in try await self.blockTime(b) })
    }
}

let alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let bob = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
let carol = "0xcccccccccccccccccccccccccccccccccccccccc"

/// Wait for a condition on the main actor, polling briefly.
@MainActor
func eventually(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

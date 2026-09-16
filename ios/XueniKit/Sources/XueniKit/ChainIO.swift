// ChainIO.swift — every chain read the reader makes, for ONE chain.
//
// Block heights and hashes in, post metadata and bytes out. It knows
// nothing about caching or traversal — that is ScanStore and Scanner —
// which is what lets a fake stand in for it and run the real reader on top.
//
// One chain, one contract: every Post event comes from Xueni at the same
// CREATE2 address, and an author's head pointer and count are that
// contract's two views.

import Foundation

public struct BlockHeader: Sendable, Equatable {
    public let number: UInt64
    public let timestamp: Int
    public let baseFeePerGas: UInt64?
}

public struct TransactionData: Sendable {
    public let input: [UInt8]
    /// The account that sent the transaction, lowercase.
    public let from: String?
}

/// A post body with what the transaction says around it.
public struct PostBody: Sendable {
    public let post: DecodedPost
    /// The account that sent the transaction, lowercase — for a relayed
    /// post, not the author.
    public let sender: String?
}

public final class ChainIO: ChainReadIO, @unchecked Sendable {
    public let chain: Chain
    public var chainId: Int { chain.id }
    public let rpc: RPCClient
    private let brotli: BrotliDecompressor
    private let times = BlockTimeCache()
    /// How many times to lower the window top before giving up on it.
    private let headRetries = 3

    public init(chain: Chain, rpc: RPCClient, brotli: BrotliDecompressor) {
        self.chain = chain
        self.rpc = rpc
        self.brotli = brotli
    }

    // MARK: - Blocks

    public func blockNumber() async throws -> UInt64 {
        let out = try await rpc.call("eth_blockNumber", [])
        guard let s = out.string, let n = Hex.parseQuantity(s) else { throw ChainError.malformed("eth_blockNumber") }
        return n
    }

    public func block(_ number: UInt64) async throws -> BlockHeader {
        try await header(.string(Hex.quantity(number)))
    }

    public func latestBlock() async throws -> BlockHeader {
        try await header(.string("latest"))
    }

    private func header(_ which: JSON) async throws -> BlockHeader {
        let out = try await rpc.call("eth_getBlockByNumber", [which, .bool(false)])
        guard let number = out.quantity("number"), let ts = out.quantity("timestamp") else {
            throw ChainError.malformed("eth_getBlockByNumber: no such block")
        }
        return BlockHeader(number: number, timestamp: Int(ts), baseFeePerGas: out.quantity("baseFeePerGas"))
    }

    /// When `block` was mined, in seconds — once per block, kept for good.
    public func blockTime(_ block: UInt64) async throws -> Int {
        try await times.time(for: block) { try await self.block(block).timestamp }
    }

    /// `{ block, ts, secondsPerBlock }` — the newest block and how fast
    /// blocks have been coming, measured over the last thousand.
    public func clock() async throws -> ChainClock {
        let latest = try await latestBlock()
        let sample: UInt64 = 1000
        var pace = 12.0
        if latest.number > sample {
            let older = try await block(latest.number - sample)
            let blocks = Double(latest.number - older.number)
            let seconds = Double(latest.timestamp - older.timestamp)
            if blocks > 0 && seconds > 0 { pace = seconds / blocks }
        }
        return ChainClock(block: latest.number, ts: latest.timestamp, secondsPerBlock: pace)
    }

    // MARK: - The contract's views

    private func view(_ data: String, label: String) async throws -> UInt64 {
        let out = try await rpc.call("eth_call", [.object(["to": .string(Chains.xueniAddress), "data": .string(data)]), .string("latest")])
        guard let s = out.string else { throw ChainError.malformed("\(label): no answer") }
        // A view called on an address with no code answers `0x`: the
        // contract is not deployed here, which means "no posts here".
        if s == "0x" || s.isEmpty { return 0 }
        guard let bytes = Hex.bytes(s), bytes.count >= 32, let n = ABI.uint64(word: bytes[0..<32]) else {
            throw ChainError.malformed("\(label): not a number")
        }
        return n
    }

    /// The block holding `author`'s newest post (0 when they have none).
    public func latestBlock(author: String) async throws -> UInt64 {
        guard let data = ABI.latestBlockCall(author) else { throw ChainError.malformed("not an address") }
        return try await view(data, label: "latestBlock")
    }

    /// How many posts `author` has published on this chain.
    public func count(author: String) async throws -> UInt64 {
        guard let data = ABI.countCall(author) else { throw ChainError.malformed("not an address") }
        return try await view(data, label: "count")
    }

    /// Whether an address holds code: a contract account, as against a key.
    public func hasCode(_ address: String) async throws -> Bool {
        let out = try await rpc.call("eth_getCode", [.string(address.lowercased()), .string("latest")])
        guard let s = out.string else { return false }
        return s != "0x" && !s.isEmpty
    }

    // MARK: - Logs

    private func authorTopic(_ author: String) -> String? {
        ABI.addressWord(author).map(Hex.string)
    }

    private func getLogs(from: UInt64, to: UInt64, author: String?) async throws -> [JSON] {
        var topics: [JSON] = [.string(ABI.postEventTopic)]
        if let author = author {
            guard let topic = authorTopic(author) else { throw ChainError.malformed("not an address") }
            topics.append(.string(topic))
        }
        let filter: JSON = .object([
            "address": .string(Chains.xueniAddress),
            "topics": .array(topics),
            "fromBlock": .string(Hex.quantity(from)),
            "toBlock": .string(Hex.quantity(to)),
        ])
        let out = try await Retry.withBackoff { try await rpc.call("eth_getLogs", [filter]) }
        guard let logs = out.array else { throw ChainError.malformed("eth_getLogs: not a list") }
        return logs
    }

    /// One transaction can publish several posts, so a txHash is not a
    /// unique post id: each Post log is tagged with its 0-based ordinal
    /// among the Post events of its transaction, by log index.
    private func rows(from logs: [JSON], block: UInt64? = nil) -> [PostRow] {
        struct Entry {
            let event: ABI.PostEvent
            let block: UInt64
            let txHash: String
            let logIndex: Int
            let ts: Int?
        }
        var entries: [Entry] = []
        for log in logs {
            guard let address = log["address"]?.string, Chains.isContract(address) else { continue }
            guard let topics = log["topics"]?.array?.compactMap({ $0.string }), let data = log["data"]?.string else { continue }
            guard let event = ABI.decodePostEvent(topics: topics, data: data) else { continue }
            guard let txHash = log["transactionHash"]?.string, Hex.isHash(txHash) else { continue }
            guard let number = block ?? log.quantity("blockNumber") else { continue }
            let logIndex = Int(log.quantity("logIndex") ?? 0)
            // The block's timestamp when the node put it on the log (geth ≥
            // 1.14 and Erigon do); otherwise looked up, see withTimes().
            let ts = log.quantity("blockTimestamp").map(Int.init)
            entries.append(Entry(event: event, block: number, txHash: txHash.lowercased(), logIndex: logIndex, ts: ts))
        }
        var byTx: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() { byTx[e.txHash, default: []].append(i) }
        var ordinal = [Int](repeating: 0, count: entries.count)
        for (_, idx) in byTx {
            let sorted = idx.sorted { entries[$0].logIndex < entries[$1].logIndex }
            for (n, i) in sorted.enumerated() { ordinal[i] = n }
        }
        return entries.enumerated().map { i, e in
            PostRow(
                chainId: chain.id,
                author: e.event.author,
                index: e.event.index,
                block: e.block,
                prevBlock: e.event.prevBlock,
                title: e.event.title,
                txHash: e.txHash,
                eventIndex: ordinal[i],
                logIndex: e.logIndex,
                ts: e.ts,
                hook: e.event.hook
            )
        }
    }

    /// Attach `ts` to rows that lack it — one header read per distinct
    /// block, a few in flight at a time, best-effort.
    private func withTimes(_ rows: [PostRow]) async -> [PostRow] {
        let missing = Array(Set(rows.filter { $0.ts == nil }.map { $0.block }))
        guard !missing.isEmpty else { return rows }
        var found: [UInt64: Int] = [:]
        await withTaskGroup(of: (UInt64, Int?).self) { group in
            var pending = missing[...]
            var running = 0
            func launch(_ b: UInt64) {
                group.addTask { (b, try? await self.blockTime(b)) }
            }
            while running < 4, let b = pending.popFirst() { launch(b); running += 1 }
            for await (b, ts) in group {
                if let ts = ts { found[b] = ts }
                if let next = pending.popFirst() { launch(next) }
            }
        }
        return rows.map { r in
            var row = r
            if row.ts == nil { row.ts = found[row.block] }
            return row
        }
    }

    /// Every Post event in `[from, to]`, all authors. Returns the top block
    /// actually read: when the node hasn't seen `to` yet the window is
    /// retried one block shorter, up to `headRetries` times.
    public func postsInRange(from: UInt64, to: UInt64) async throws -> RangeResult {
        var top = to
        var attempt = 0
        while true {
            do {
                let logs = try await getLogs(from: from, to: top, author: nil)
                let rows = await withTimes(self.rows(from: logs))
                return RangeResult(rows: rows, to: top)
            } catch let error as ChainError {
                if error.isBeyondHead && top > from && attempt < headRetries {
                    top -= 1
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    /// `author`'s Post events in one block.
    public func authorPostsInBlock(author: String, block: UInt64) async throws -> [PostRow] {
        let logs = try await getLogs(from: block, to: block, author: author)
        let who = author.lowercased()
        return await withTimes(rows(from: logs, block: block).filter { $0.author == who })
    }

    /// Every Post event a transaction emitted, in log order — one receipt
    /// read, no scanning. Empty when the transaction published nothing.
    public func postsInTx(_ txHash: String) async throws -> [PostRow] {
        let out = try await Retry.withBackoff { try await rpc.call("eth_getTransactionReceipt", [.string(txHash.lowercased())]) }
        guard !out.isNull else { throw ChainError.malformed("no receipt yet") }
        guard let logs = out["logs"]?.array, let block = out.quantity("blockNumber") else {
            throw ChainError.malformed("eth_getTransactionReceipt: not a receipt")
        }
        var rows = self.rows(from: logs, block: block).sorted { ($0.logIndex ?? 0) < ($1.logIndex ?? 0) }
        if !rows.isEmpty {
            let ts = try? await blockTime(block)
            for i in rows.indices where rows[i].ts == nil { rows[i].ts = ts }
        }
        return rows
    }

    // MARK: - Transactions

    public func transaction(_ txHash: String) async throws -> TransactionData {
        let out = try await rpc.call("eth_getTransactionByHash", [.string(txHash.lowercased())])
        guard !out.isNull, let input = out["input"]?.string, let bytes = Hex.bytes(input) else {
            throw ChainError.malformed("eth_getTransactionByHash: no such transaction")
        }
        return TransactionData(input: bytes, from: out["from"]?.string?.lowercased())
    }

    /// The body of a post, decoded from its publish transaction's calldata.
    public func postBody(_ txHash: String) async throws -> PostBody {
        let tx = try await transaction(txHash)
        let brotli = self.brotli
        let input = tx.input
        // Decompression and parsing off the caller's actor: a long letter
        // is real work, and nothing here needs to happen on the main thread.
        let post = try await Task.detached(priority: .userInitiated) {
            try Codec.readPost(callData: input, with: brotli)
        }.value
        return PostBody(post: post, sender: tx.from)
    }

    /// The raw bytes an image transaction carries as calldata.
    public func imageBytes(_ txHash: String) async throws -> [UInt8] {
        try await transaction(txHash).input
    }

    // MARK: - Raw calls (ENS)

    /// `eth_call` to any contract, the answer as bytes (`[]` for `0x`).
    public func call(to: String, data: [UInt8]) async throws -> [UInt8] {
        let out = try await rpc.call("eth_call", [.object(["to": .string(to), "data": .string(Hex.string(data))]), .string("latest")])
        guard let s = out.string, let bytes = Hex.bytes(s) else { throw ChainError.malformed("eth_call: no answer") }
        return bytes
    }
}

/// A block's timestamp, once per block for the life of the reader. Blocks
/// are immutable once mined, so the answer is kept for good — except on
/// failure, which is dropped so the next asker retries.
actor BlockTimeCache {
    private var tasks: [UInt64: Task<Int, Error>] = [:]

    func time(for block: UInt64, _ read: @escaping @Sendable () async throws -> Int) async throws -> Int {
        if let hit = tasks[block] { return try await hit.value }
        let task = Task { try await read() }
        tasks[block] = task
        do {
            return try await task.value
        } catch {
            tasks[block] = nil
            throw error
        }
    }
}

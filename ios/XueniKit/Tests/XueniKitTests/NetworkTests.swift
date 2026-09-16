import Foundation
import XCTest
@testable import XueniKit

/// An HTTP layer that answers by URL, and remembers the order it was asked in.
final class FakeRequester: RPCRequester, @unchecked Sendable {
    enum Answer {
        case ok(String) // the `result` JSON text
        case rpcError(Int, String)
        case http(Int)
        case network
    }

    private let lock = NSLock()
    var answers: [String: Answer] = [:]
    var calls: [String] = []

    init(_ answers: [String: Answer]) {
        self.answers = answers
    }

    private func record(_ url: URL) -> Answer? {
        lock.lock()
        defer { lock.unlock() }
        calls.append(url.host ?? url.absoluteString)
        return answers[url.absoluteString]
    }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async throws -> (Data, Int) {
        let answer = record(url)
        switch answer {
        case .ok(let result)?:
            return (Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8), 200)
        case .rpcError(let code, let message)?:
            return (Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\(code),\"message\":\"\(message)\"}}".utf8), 200)
        case .http(let status)?:
            return (Data(), status)
        case .network?, nil:
            throw ChainError.network("connection refused")
        }
    }
}

/// A clock the test moves by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

final class TransportTests: XCTestCase {
    let a = "https://a.example/rpc"
    let b = "https://b.example/rpc"

    func testAFailedNodeIsCooledAndTriedLast() async throws {
        let requester = FakeRequester([a: .network, b: .ok("\"0x10\"")])
        let clock = Clock()
        let transport = OrderedTransport(urls: [a, b], requester: requester, now: { clock.now })
        let first = try await transport.call("eth_blockNumber", [])
        XCTAssertEqual(first, .string("0x10"))
        XCTAssertEqual(requester.calls, ["a.example", "b.example"])
        _ = try await transport.call("eth_blockNumber", [])
        XCTAssertEqual(requester.calls, ["a.example", "b.example", "b.example"], "a is cooling: b goes first")
        clock.advance(OrderedTransport.cooldown + 1)
        _ = try await transport.call("eth_blockNumber", [])
        XCTAssertEqual(requester.calls.suffix(2), ["a.example", "b.example"], "after the cool-down a is preferred again")
    }

    func testAnAnswerIsNotAFailure() async throws {
        let requester = FakeRequester([a: .rpcError(-32005, "block range too large"), b: .ok("[]")])
        let transport = OrderedTransport(urls: [a, b], requester: requester)
        _ = try await transport.call("eth_getLogs", [])
        _ = try await transport.call("eth_getLogs", [])
        XCTAssertEqual(requester.calls, ["a.example", "b.example", "a.example", "b.example"], "a answered, so it stays first")
        requester.answers[b] = .rpcError(-32005, "block range too large")
        do {
            _ = try await transport.call("eth_getLogs", [])
            XCTFail()
        } catch let error as ChainError {
            XCTAssertTrue(error.isRangeTooLarge)
            XCTAssertFalse(error.isNodeFailure)
        }
    }

    func testStatusesAndShapes() async {
        let requester = FakeRequester([a: .http(429)])
        let transport = OrderedTransport(urls: [a], requester: requester)
        do {
            _ = try await transport.call("eth_blockNumber", [])
            XCTFail()
        } catch let error as ChainError {
            XCTAssertEqual(error, .http(status: 429))
            XCTAssertTrue(error.isRateLimited)
            XCTAssertTrue(error.isNodeFailure)
        } catch { XCTFail() }
        let none = OrderedTransport(urls: [], requester: requester)
        do {
            _ = try await none.call("eth_blockNumber", [])
            XCTFail()
        } catch let error as ChainError {
            XCTAssertEqual(error, .noEndpoints)
        } catch { XCTFail() }
        await none.setURLs([a])
        let urls = await none.urls
        XCTAssertEqual(urls, [a])
    }

    func testErrorClassification() {
        XCTAssertTrue(ChainError.rpc(code: 1, message: "block range extends beyond current head block").isBeyondHead)
        XCTAssertFalse(ChainError.rpc(code: 1, message: "block range extends beyond current head block").isRateLimited)
        XCTAssertTrue(ChainError.rpc(code: 1, message: "eth_getLogs is limited to 10000 blocks").isRangeTooLarge)
        XCTAssertFalse(ChainError.rpc(code: 1, message: "rate limit exceeded").isRangeTooLarge)
        XCTAssertTrue(ChainError.rpc(code: 1, message: "rate limit exceeded").isRetriable)
        XCTAssertTrue(ChainError.network("timed out").isNodeFailure)
        XCTAssertEqual(ChainError.nodeBehind(block: 7).text, "xueni:node-behind 7")
        XCTAssertEqual(Format.errorKey(ChainError.nodeBehind(block: 7).text).block, "7")
        XCTAssertEqual(Format.errorKey("429 too many requests").key, "error.rateLimit")
    }

    func testJSONCodable() throws {
        let value: JSON = .object(["a": .array([.number(1), .string("x"), .bool(true), .null])])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSON.self, from: data)
        XCTAssertEqual(back, value)
        XCTAssertEqual(back["a"]?.array?.count, 4)
    }
}

/// A node that answers from an in-memory chain at the JSON-RPC level, so
/// that ChainIO's decoding is exercised on the wire shapes a real node uses.
final class FakeRPC: RPCClient, @unchecked Sendable {
    struct Log {
        let author: String
        let hook: String?
        let index: UInt64
        let prevBlock: UInt64
        let title: String
        let block: UInt64
        let txHash: String
        let logIndex: Int
        let withTimestamp: Bool
    }

    var logs: [Log] = []
    var latestBlocks: [String: UInt64] = [:]
    var transactions: [String: (input: String, from: String)] = [:]
    var head: UInt64 = 100
    var noContract = false
    var beyondHeadAbove: UInt64? = nil
    private let lock = NSLock()
    var calls: [String] = []

    func encode(_ log: Log) -> JSON {
        var obj: [String: JSON] = [
            "address": .string(Chains.xueniAddress),
            "topics": .array([
                .string(ABI.postEventTopic),
                .string(Hex.string(ABI.addressWord(log.author)!)),
                .string(Hex.string(ABI.addressWord(log.hook ?? ABI.zeroAddress)!)),
            ]),
            "data": .string(Hex.string(ABI.uintWord(log.index) + ABI.uintWord(log.prevBlock) + Title.encode(log.title)!)),
            "blockNumber": .string(Hex.quantity(log.block)),
            "transactionHash": .string(log.txHash),
            "logIndex": .string(Hex.quantity(UInt64(log.logIndex))),
        ]
        if log.withTimestamp { obj["blockTimestamp"] = .string(Hex.quantity(UInt64(1_700_000_000 + log.block))) }
        return .object(obj)
    }

    private func record(_ method: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(method)
    }

    func call(_ method: String, _ params: [JSON]) async throws -> JSON {
        record(method)
        switch method {
        case "eth_blockNumber":
            return .string(Hex.quantity(head))
        case "eth_getBlockByNumber":
            guard let which = params.first?.string else { throw ChainError.malformed("no block") }
            let number = which == "latest" ? head : Hex.parseQuantity(which)!
            return .object(["number": .string(Hex.quantity(number)), "timestamp": .string(Hex.quantity(1_700_000_000 + number)), "baseFeePerGas": .string("0x3b9aca00")])
        case "eth_call":
            if noContract { return .string("0x") }
            let data = params[0]["data"]!.string!
            let bytes = Hex.bytes(data)!
            let author = ABI.address(word: bytes[4..<36])!
            if Array(bytes.prefix(4)) == ABI.latestBlockSelector { return .string(Hex.string(ABI.uintWord(latestBlocks[author] ?? 0))) }
            if Array(bytes.prefix(4)) == ABI.countSelector { return .string(Hex.string(ABI.uintWord(UInt64(logs.filter { $0.author == author }.count)))) }
            throw ChainError.rpc(code: 3, message: "execution reverted")
        case "eth_getLogs":
            let filter = params[0]
            let from = Hex.parseQuantity(filter["fromBlock"]!.string!)!
            let to = Hex.parseQuantity(filter["toBlock"]!.string!)!
            if let limit = beyondHeadAbove, to > limit { throw ChainError.rpc(code: -32000, message: "block range extends beyond current head block") }
            let topics = filter["topics"]!.array!
            let author = topics.count > 1 ? ABI.address(topic: topics[1].string!) : nil
            return .array(logs.filter { $0.block >= from && $0.block <= to && (author == nil || $0.author == author) }.map(encode))
        case "eth_getTransactionByHash":
            let hash = params[0].string!
            guard let tx = transactions[hash] else { return .null }
            return .object(["hash": .string(hash), "input": .string(tx.input), "from": .string(tx.from)])
        case "eth_getTransactionReceipt":
            let hash = params[0].string!
            let mine = logs.filter { $0.txHash == hash }
            guard let first = mine.first else { return .null }
            return .object(["blockNumber": .string(Hex.quantity(first.block)), "logs": .array(mine.map(encode))])
        case "eth_getCode":
            return .string(params[0].string == Chains.xueniAddress ? "0x6080" : "0x")
        default:
            throw ChainError.rpc(code: -32601, message: "method not found")
        }
    }
}

final class ChainIOTests: XCTestCase {
    let tx1 = "0x" + String(repeating: "11", count: 32)
    let tx2 = "0x" + String(repeating: "22", count: 32)

    func makeIO(_ rpc: FakeRPC) -> ChainIO {
        ChainIO(chain: Chains.ethereum, rpc: rpc, brotli: VectorBrotli())
    }

    func testLogsBecomeRowsWithOrdinalsAndTimes() async throws {
        let rpc = FakeRPC()
        rpc.logs = [
            FakeRPC.Log(author: alice, hook: nil, index: 0, prevBlock: 0, title: "first", block: 50, txHash: tx1, logIndex: 3, withTimestamp: true),
            FakeRPC.Log(author: bob, hook: Chains.multiHookAddress, index: 0, prevBlock: 0, title: "多个", block: 50, txHash: tx1, logIndex: 5, withTimestamp: true),
            FakeRPC.Log(author: alice, hook: nil, index: 1, prevBlock: 50, title: "second", block: 60, txHash: tx2, logIndex: 0, withTimestamp: false),
        ]
        let io = makeIO(rpc)
        let result = try await io.postsInRange(from: 0, to: 100)
        XCTAssertEqual(result.to, 100)
        let rows = result.rows.sorted(by: PostRow.feedBefore)
        XCTAssertEqual(rows.map { $0.title }, ["second", "多个", "first"])
        XCTAssertEqual(rows.map { $0.eventIndex }, [0, 1, 0])
        XCTAssertEqual(rows[1].hook, Chains.multiHookAddress)
        XCTAssertNil(rows[2].hook)
        XCTAssertEqual(rows[2].ts, 1_700_000_050)
        XCTAssertEqual(rows[0].ts, 1_700_000_060, "a row without a timestamp on the log gets one from the header")
        XCTAssertEqual(rpc.calls.filter { $0 == "eth_getBlockByNumber" }.count, 1)

        let alices = try await io.authorPostsInBlock(author: alice, block: 50)
        XCTAssertEqual(alices.map { $0.title }, ["first"])
        XCTAssertEqual(alices[0].eventIndex, 0)

        let inTx = try await io.postsInTx(tx1)
        XCTAssertEqual(inTx.map { $0.author }, [alice, bob])
        XCTAssertEqual(inTx.map { $0.eventIndex }, [0, 1])
    }

    func testViewsAndTheMissingContract() async throws {
        let rpc = FakeRPC()
        rpc.latestBlocks[alice] = 77
        let io = makeIO(rpc)
        let aliceHead = try await io.latestBlock(author: alice)
        XCTAssertEqual(aliceHead, 77)
        let bobHead = try await io.latestBlock(author: bob)
        XCTAssertEqual(bobHead, 0)
        rpc.noContract = true
        let missing = try await io.latestBlock(author: alice)
        XCTAssertEqual(missing, 0, "no code at the address reads as no posts")
        let head = try await io.blockNumber()
        XCTAssertEqual(head, 100)
        let contractHasCode = try await io.hasCode(Chains.xueniAddress)
        XCTAssertTrue(contractHasCode)
        let keyHasCode = try await io.hasCode(alice)
        XCTAssertFalse(keyHasCode)
        let clock = try await io.clock()
        XCTAssertEqual(clock.block, 100)
        XCTAssertEqual(clock.secondsPerBlock, 12)
    }

    func testTheHeadIsLoweredWhenTheNodeIsBehind() async throws {
        let rpc = FakeRPC()
        rpc.beyondHeadAbove = 98
        let io = makeIO(rpc)
        let result = try await io.postsInRange(from: 0, to: 100)
        XCTAssertEqual(result.to, 98)
        XCTAssertEqual(rpc.calls.filter { $0 == "eth_getLogs" }.count, 3)
    }

    func testBodiesComeBackAsPosts() async throws {
        let rpc = FakeRPC()
        let vector = Vectors.all[2]
        rpc.transactions[tx1] = (vector.callData, alice)
        let io = makeIO(rpc)
        let body = try await io.postBody(tx1)
        XCTAssertEqual(body.post.title, vector.post.title)
        XCTAssertEqual(body.post.tags, vector.post.tags)
        XCTAssertEqual(body.sender, alice)
        let image = try await io.imageBytes(tx1)
        XCTAssertEqual(image.count, Hex.bytes(vector.callData)!.count)
        do {
            _ = try await io.postBody(tx2)
            XCTFail()
        } catch let error as ChainError {
            XCTAssertEqual(error, .malformed("eth_getTransactionByHash: no such transaction"))
        }
    }
}

final class ENSTests: XCTestCase {
    func testNamehash() {
        XCTAssertEqual(Hex.string(ENS.namehash("")), "0x0000000000000000000000000000000000000000000000000000000000000000")
        XCTAssertEqual(Hex.string(ENS.namehash("eth")), "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae")
        XCTAssertEqual(Hex.string(ENS.namehash("vitalik.eth")), "0xee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835")
        XCTAssertEqual(Hex.string(ENS.namehash("xiaoman.eth")), "0xfeec2c7fa6866472d70a4eb65d191f193bef847d4062aa1927466379c3d404b0")
        XCTAssertEqual(Hex.string(ENS.reverseNode("0x8a1f3b52c9e44e1a9b1f0d2c7a44e0b1d2e3f4a5")), "0x978fb4f6acf8cc88b0600664cedea0adac2fab4cb1ad382955575a8eb68857a2")
    }

    func testNamesAndNormalisation() {
        XCTAssertTrue(ENS.isName("xiaoman.eth"))
        XCTAssertTrue(ENS.isName("Sub.Xiaoman.eth"))
        XCTAssertFalse(ENS.isName("xiaoman.com"))
        XCTAssertFalse(ENS.isName(".eth"))
        XCTAssertFalse(ENS.isName("0x8a1f3b52c9e44e1a9b1f0d2c7a44e0b1d2e3f4a5"))
        XCTAssertEqual(ENS.normalize(" Xiaoman.ETH "), "xiaoman.eth")
        XCTAssertNil(ENS.normalize("a b.eth"))
        XCTAssertNil(ENS.normalize("a..eth"))
    }

    func testCallEncodings() {
        let node = ENS.namehash("xiaoman.eth")
        XCTAssertEqual(Array(ENS.resolverCall(node).prefix(4)), [0x01, 0x78, 0xb8, 0xbf])
        let text = ENS.textCall(node, key: "com.twitter")
        XCTAssertEqual(text.count, 4 + 32 + 32 + 32 + 32)
        XCTAssertEqual(Array(text[36..<68]), ABI.uintWord(64))
        XCTAssertEqual(Array(text[68..<100]), ABI.uintWord(11))
        XCTAssertEqual(String(decoding: text[100..<111], as: UTF8.self), "com.twitter")
        let encoded = ABI.uintWord(32) + ABI.uintWord(5) + Array("hello".utf8) + [UInt8](repeating: 0, count: 27)
        XCTAssertEqual(ENS.decodeString(encoded), "hello")
        XCTAssertNil(ENS.decodeString(ABI.uintWord(32)))
        XCTAssertNil(ENS.decodeAddress(ABI.uintWord(0)))
        XCTAssertEqual(ENS.decodeAddress(ABI.addressWord(alice)!), alice)
    }

    func testAReverseClaimMustResolveForward() async {
        let rpc = ENSFakeRPC()
        rpc.reverseName[alice] = "alice.eth"
        rpc.forward["alice.eth"] = bob // claims a name that points elsewhere
        let ens = ENSResolver(io: ChainIO(chain: Chains.ethereum, rpc: rpc, brotli: VectorBrotli()))
        let name = await ens.name(for: alice)
        XCTAssertNil(name)
        rpc.forward["alice.eth"] = alice
        let honest = await ens.name(for: bob) // bob has no reverse record at all
        XCTAssertNil(honest)
        let fresh = ENSResolver(io: ChainIO(chain: Chains.ethereum, rpc: rpc, brotli: VectorBrotli()))
        let verified = await fresh.name(for: alice)
        XCTAssertEqual(verified, "alice.eth")
        let address = await fresh.address(for: "Alice.eth")
        XCTAssertEqual(address, alice)
        rpc.texts["alice.eth:description"] = "letters home"
        let description = await fresh.text("alice.eth", key: "description")
        XCTAssertEqual(description, "letters home")
    }
}

/// A registry and one resolver, at the calldata level.
final class ENSFakeRPC: RPCClient, @unchecked Sendable {
    let resolver = "0x1111111111111111111111111111111111111111"
    var reverseName: [String: String] = [:]
    var forward: [String: String] = [:]
    var texts: [String: String] = [:]

    private func encodeString(_ s: String) -> String {
        let bytes = Array(s.utf8)
        return Hex.string(ABI.uintWord(32) + ABI.uintWord(UInt64(bytes.count)) + bytes + [UInt8](repeating: 0, count: (32 - bytes.count % 32) % 32))
    }

    func call(_ method: String, _ params: [JSON]) async throws -> JSON {
        guard method == "eth_call" else { throw ChainError.rpc(code: -32601, message: "method not found") }
        let to = params[0]["to"]!.string!
        let data = Hex.bytes(params[0]["data"]!.string!)!
        let selector = Array(data.prefix(4))
        let node = Array(data[4..<36])
        if to == ENS.registry {
            return .string(Hex.string(ABI.addressWord(resolver)!))
        }
        if selector == [0x69, 0x1f, 0x34, 0x31] { // name(bytes32)
            for (address, name) in reverseName where ENS.reverseNode(address) == node { return .string(encodeString(name)) }
            return .string(encodeString(""))
        }
        if selector == [0x3b, 0x3b, 0x57, 0xde] { // addr(bytes32)
            for (name, address) in forward where ENS.namehash(name) == node { return .string(Hex.string(ABI.addressWord(address)!)) }
            return .string(Hex.string(ABI.uintWord(0)))
        }
        if selector == [0x59, 0xd1, 0xd4, 0x3c] { // text(bytes32,string)
            let args = Array(data[4...])
            let offset = Int(ABI.uint64(word: args[32..<64])!)
            let length = Int(ABI.uint64(word: args[offset..<(offset + 32)])!)
            let key = String(decoding: args[(offset + 32)..<(offset + 32 + length)], as: UTF8.self)
            for (name, _) in forward where ENS.namehash(name) == node { return .string(encodeString(texts["\(name):\(key)"] ?? "")) }
            return .string(encodeString(""))
        }
        throw ChainError.rpc(code: 3, message: "execution reverted")
    }
}

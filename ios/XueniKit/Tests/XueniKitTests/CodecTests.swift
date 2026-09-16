import Foundation
import XCTest
@testable import XueniKit

final class HexTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(Hex.string([0, 1, 0xab, 0xff]), "0x0001abff")
        XCTAssertEqual(Hex.bytes("0x0001ABff"), [0, 1, 0xab, 0xff])
        XCTAssertEqual(Hex.bytes("0001abff"), [0, 1, 0xab, 0xff])
        XCTAssertEqual(Hex.bytes("0x"), [])
        XCTAssertNil(Hex.bytes("0x0"))
        XCTAssertNil(Hex.bytes("0xzz"))
    }

    func testQuantities() {
        XCTAssertEqual(Hex.quantity(0), "0x0")
        XCTAssertEqual(Hex.quantity(25_980_697), "0x18c6f19")
        XCTAssertEqual(Hex.parseQuantity("0x18c6f19"), 25_980_697)
        XCTAssertEqual(Hex.parseQuantity("0x0"), 0)
        XCTAssertNil(Hex.parseQuantity("0x"))
        XCTAssertNil(Hex.parseQuantity("0x10000000000000000"))
    }

    func testShapes() {
        XCTAssertTrue(Hex.isAddress(Chains.xueniAddress))
        XCTAssertTrue(Hex.isAddress("0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d9"))
        XCTAssertFalse(Hex.isAddress("0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d"))
        XCTAssertTrue(Hex.isHash("0x" + String(repeating: "ab", count: 32)))
        XCTAssertFalse(Hex.isHash("0x" + String(repeating: "ab", count: 31)))
    }
}

final class KeccakTests: XCTestCase {
    func testKnownDigests() {
        XCTAssertEqual(Hex.string(Keccak.hash256([])), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(Hex.string(Keccak.hash256("abc")), "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        // Longer than one block, so the absorb loop runs more than once.
        XCTAssertEqual(Hex.string(Keccak.hash256(String(repeating: "a", count: 200))), "0x96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d")
    }

    func testTheConstantsInABIAreKeccaks() {
        XCTAssertEqual(Hex.string(Keccak.hash256("Post(address,address,uint256,uint256,bytes32)")), ABI.postEventTopic)
        XCTAssertEqual(Array(Keccak.hash256("latestBlock(address)").prefix(4)), ABI.latestBlockSelector)
        XCTAssertEqual(Array(Keccak.hash256("count(address)").prefix(4)), ABI.countSelector)
        XCTAssertEqual(Array(Keccak.hash256("publish(bytes32,bytes)").prefix(4)), ABI.publishSelector)
        XCTAssertEqual(Array(Keccak.hash256("publish(bytes32,bytes,address,bytes)").prefix(4)), ABI.publishWithHookSelector)
        XCTAssertEqual(Array(Keccak.hash256("publishFor(address,bytes32,bytes,address,bytes,uint256,bytes)").prefix(4)), ABI.publishForSelector)
        for (name, selector) in Vectors.file.selectors {
            let signature = ["publish": "publish(bytes32,bytes)", "publishWithHook": "publish(bytes32,bytes,address,bytes)", "publishFor": "publishFor(address,bytes32,bytes,address,bytes,uint256,bytes)"][name]!
            XCTAssertEqual(Hex.string(Array(Keccak.hash256(signature).prefix(4))), selector)
        }
    }
}

final class TitleTests: XCTestCase {
    func testEncodeDecode() {
        let word = Title.encode("Just prose")!
        XCTAssertEqual(word.count, 32)
        XCTAssertEqual(Hex.string(word), "0x4a7573742070726f736500000000000000000000000000000000000000000000")
        XCTAssertEqual(Title.decode(word), "Just prose")
        XCTAssertEqual(Title.decode(Title.encode("")!), "")
        XCTAssertNil(Title.encode(String(repeating: "x", count: 33)))
        XCTAssertEqual(Title.byteLength("关于外婆的香樟木箱"), 27)
        XCTAssertEqual(Title.byteLength("😀😀😀😀😀😀😀😀"), 32)
    }

    func testACutMultibyteTailReadsWithReplacement() {
        var bytes = Array("关于外婆的香樟木箱".utf8)
        bytes.removeLast() // cut mid-character
        let word = bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
        let decoded = Title.decode(word)
        XCTAssertTrue(decoded.hasPrefix("关于外婆的香樟木"))
        XCTAssertTrue(decoded.hasSuffix("\u{FFFD}"))
        XCTAssertEqual(Title.forDisplay(decoded), "关于外婆的香樟木")
        XCTAssertNil(Title.forDisplay("\u{FFFD}"))
    }

    func testFitAndProblems() {
        XCTAssertEqual(Title.fit("关于外婆的香樟木箱子里的东西"), "关于外婆的香樟木箱子")
        XCTAssertEqual(Title.problems("ok"), [])
        XCTAssertEqual(Title.problems("a\u{0}b"), ["TITLE_NUL", "CONTROL_CHAR"])
        XCTAssertEqual(Title.problems("tab\tok"), [])
    }
}

final class DocumentTests: XCTestCase {
    func testTheSpecExample() {
        let doc = Document.parse("---\ntags: letters home, 冬\nlang: zh\n---\n\n# 冬至\n\n正文。\n")
        XCTAssertEqual(doc.tags, ["letters home", "冬"])
        XCTAssertEqual(doc.meta["lang"], "zh")
        XCTAssertEqual(doc.markdown, "# 冬至\n\n正文。\n")
        XCTAssertEqual(doc.metaOrder, ["tags", "lang"])
    }

    func testARuleAtTheTopIsBody() {
        let text = "---\n\nprose\n\n---\n"
        let doc = Document.parse(text)
        XCTAssertTrue(doc.meta.isEmpty)
        XCTAssertEqual(doc.markdown, text)
    }

    func testNoClosingDelimiterIsBody() {
        let text = "---\nfoo: bar\n\nprose"
        XCTAssertEqual(Document.parse(text).markdown, text)
    }

    func testBracketTagsBlankLinesAndDuplicateKeys() {
        let doc = Document.parse("---\ntags: [a, b]\n\nlang: en\nlang: zh\n---\nbody")
        XCTAssertEqual(doc.tags, ["a", "b"])
        XCTAssertEqual(doc.meta["lang"], "zh")
        XCTAssertEqual(doc.markdown, "body")
    }

    func testCRLFReadsTheSame() {
        let doc = Document.parse("---\r\ntags: x\r\n---\r\n\r\none\r\ntwo\r\n")
        XCTAssertEqual(doc.tags, ["x"])
        // The separator a writer emits is one LF; a CR before it belongs to the body.
        XCTAssertEqual(doc.markdown, "\r\none\r\ntwo\r\n")
        XCTAssertEqual(Document.lines(of: "a\r\nb\n\nc"), ["a\r", "b", "", "c"])
    }

    func testBuildFollowsTheWriterRules() {
        XCTAssertEqual(Document.build(markdown: "Just prose.\n"), "Just prose.\n")
        XCTAssertEqual(Document.build(markdown: "b", tags: ["family", " travel "]), "---\ntags: family, travel\n---\n\nb")
        XCTAssertEqual(Document.build(markdown: "---\nfoo: bar\n---\n\nrest"), "---\n---\n\n---\nfoo: bar\n---\n\nrest")
        let text = Document.build(markdown: "x", tags: ["t"], meta: ["zeta": "1", "lang": "zh", "Beta": "2", "part": " 3 ", "series": "S", "empty": "  "])
        XCTAssertEqual(text, "---\ntags: t\nlang: zh\nseries: S\npart: 3\nBeta: 2\nzeta: 1\n---\n\nx")
    }

    func testBuildAndParseRoundTripEveryVector() {
        for v in Vectors.all {
            let text = Document.build(markdown: v.post.markdown, tags: v.post.tags, meta: v.post.meta)
            XCTAssertEqual(text, v.text, v.name)
            let doc = Document.parse(text)
            XCTAssertEqual(doc.tags, v.post.tags, v.name)
            XCTAssertEqual(doc.markdown, v.post.markdown, v.name)
            XCTAssertEqual(doc.meta.filter { $0.key != "tags" }, v.post.meta, v.name)
        }
    }

    func testControlCharactersAndKeys() {
        XCTAssertTrue(Document.hasControlCharacters("a\u{1b}b", allowing: ["\t"]))
        XCTAssertFalse(Document.hasControlCharacters("a\tb", allowing: ["\t"]))
        XCTAssertTrue(Document.isValidKey("somethingLater"))
        XCTAssertTrue(Document.isValidKey("a-b_c9"))
        XCTAssertFalse(Document.isValidKey("9a"))
        XCTAssertFalse(Document.isValidKey("a b"))
    }
}

final class CodecTests: XCTestCase {
    func testEveryVectorDecodes() throws {
        for v in Vectors.all {
            let call = try Codec.decodeCallData(hex: v.callData)
            XCTAssertEqual(Hex.string(call.titleWord), v.title, v.name)
            XCTAssertEqual(call.title, v.post.title, v.name)
            XCTAssertEqual(call.payload.count, v.compressedBytes, v.name)
            if let expected = v.call {
                XCTAssertEqual(call.hook, expected.hook, v.name)
                XCTAssertEqual(Hex.string(call.hookData), expected.hookData ?? "0x", v.name)
                if let relayed = expected.relayed {
                    XCTAssertEqual(call.form, .publishFor, v.name)
                    XCTAssertEqual(call.relayed?.author, relayed.author, v.name)
                    XCTAssertEqual(call.relayed?.deadline, relayed.deadline, v.name)
                    XCTAssertEqual(call.relayed.map { Hex.string($0.signature) }, relayed.signature, v.name)
                } else {
                    XCTAssertEqual(call.form, .publishWithHook, v.name)
                }
            } else {
                XCTAssertEqual(call.form, .publish, v.name)
                XCTAssertNil(call.hook)
            }
        }
    }

    func testTheWholeTripOverTheVectorTable() throws {
        for v in Vectors.all {
            let post = try Codec.readPost(callData: Hex.bytes(v.callData)!, with: VectorBrotli())
            XCTAssertEqual(post.title, v.post.title, v.name)
            XCTAssertEqual(post.tags, v.post.tags, v.name)
            XCTAssertEqual(post.markdown, v.post.markdown, v.name)
            XCTAssertEqual(post.meta.filter { $0.key != "tags" }, v.post.meta, v.name)
            XCTAssertEqual(post.text, v.text, v.name)
            XCTAssertEqual(post.compressedBytes, v.compressedBytes, v.name)
        }
    }

    func testRefusals() {
        XCTAssertThrowsError(try Codec.decodeCallData(hex: "0x12345678" + String(repeating: "00", count: 64))) { error in
            XCTAssertEqual(error as? CodecError, .notAPublishCall(selector: "0x12345678"))
        }
        XCTAssertThrowsError(try Codec.decodeCallData(hex: "0x70a7"))
        // A payload cut short: the length word promises more than there is.
        // (Dropping only padding is fine, per §6.3 step 4: the cut has to reach the payload.)
        XCTAssertNoThrow(try Codec.decodeCallData(hex: String(Vectors.all[0].callData.dropLast(4))))
        let cut = String(Vectors.all[0].callData.dropLast(2 * 40))
        XCTAssertThrowsError(try Codec.decodeCallData(hex: cut))
        // An offset that leaves no room for a length word.
        var bytes = Hex.bytes(Vectors.all[0].callData)!
        bytes[4 + 63] = 0xff
        XCTAssertThrowsError(try Codec.decodeCallData(bytes))
        // A hook word with a non-zero upper half is not an address.
        var hooked = Hex.bytes(Vectors.all[7].callData)!
        hooked[4 + 64] = 0x01
        XCTAssertThrowsError(try Codec.decodeCallData(hooked))
    }

    func testBytesAfterTheTailAreAccepted() throws {
        let extra = Vectors.all[0].callData + "deadbeef"
        let call = try Codec.decodeCallData(hex: extra)
        XCTAssertEqual(call.payload.count, Vectors.all[0].compressedBytes)
    }

    func testVersionDetection() {
        XCTAssertEqual(try Payload.detectFormatVersion([0x0b]), 1)
        XCTAssertEqual(try Payload.detectFormatVersion([0x91, 0x02, 0x00]), 2)
        XCTAssertThrowsError(try Payload.detectFormatVersion([])) { XCTAssertEqual($0 as? PayloadError, .emptyPayload) }
        XCTAssertThrowsError(try Payload.detectFormatVersion([0x91])) { XCTAssertEqual($0 as? PayloadError, .malformedPayload("malformed version envelope")) }
        XCTAssertThrowsError(try Payload.detectFormatVersion([0x91, 0x01])) { XCTAssertEqual($0 as? PayloadError, .malformedPayload("malformed version envelope")) }
        XCTAssertThrowsError(try Payload.decode([0x91, 0x07, 0xaa], with: VectorBrotli())) { XCTAssertEqual($0 as? PayloadError, .unsupportedFormatVersion(7)) }
    }

    func testTheBoundIsEnforcedEitherWay() {
        // A decompressor that honours the bound refuses; one that ignores it is measured after.
        XCTAssertThrowsError(try Payload.decode([0xbb], with: VectorBrotli(bombBytes: 10_000), maxDocumentBytes: 100)) {
            XCTAssertEqual($0 as? PayloadError, .documentTooLarge(bound: 100))
        }
        struct Careless: BrotliDecompressor {
            func decompress(_ input: [UInt8], maxOutputBytes: Int) throws -> [UInt8] { [UInt8](repeating: 0x20, count: 200) }
        }
        XCTAssertThrowsError(try Payload.decode([0xbb], with: Careless(), maxDocumentBytes: 100)) {
            XCTAssertEqual($0 as? PayloadError, .documentTooLarge(bound: 100))
        }
        XCTAssertNoThrow(try Payload.decode([0xbb], with: VectorBrotli(bombBytes: 50), maxDocumentBytes: 100))
    }

    #if canImport(Compression)
    func testAppleBrotliDecodesTheReferencePayloads() throws {
        for v in Vectors.all {
            let post = try Codec.readPost(callData: Hex.bytes(v.callData)!, with: AppleBrotli())
            XCTAssertEqual(post.text, v.text, v.name)
        }
        XCTAssertThrowsError(try AppleBrotli().decompress([0x91, 0x02], maxOutputBytes: 1000))
        XCTAssertThrowsError(try AppleBrotli().decompress([], maxOutputBytes: 1000))
    }
    #endif
}

final class PostRefTests: XCTestCase {
    let txHash = "0x41663fee6dd678632e23c8365076b466603b0d0694925e13b0d0d2007bec7844"

    func testReferences() {
        XCTAssertEqual(PostRef.parse(txHash, defaultChainId: 1), PostRef(chainId: 1, txHash: txHash))
        XCTAssertEqual(PostRef.parse("taiko:\(txHash)/1", defaultChainId: 1), PostRef(chainId: 167_000, txHash: txHash, eventIndex: 1))
        XCTAssertEqual(PostRef.parse(txHash.uppercased().replacingOccurrences(of: "0X", with: "0x"), defaultChainId: 1)?.txHash, txHash)
        XCTAssertNil(PostRef.parse(txHash))
        XCTAssertNil(PostRef.parse("mars:\(txHash)", defaultChainId: 1))
        XCTAssertNil(PostRef.parse("\(txHash)/x", defaultChainId: 1))
        XCTAssertNil(PostRef.parse("0x1234", defaultChainId: 1))
    }

    func testURLs() {
        XCTAssertEqual(PostRef.parse("https://xueni.xyz/taiko/tx/\(txHash)/0", defaultChainId: 1), PostRef(chainId: 167_000, txHash: txHash))
        XCTAssertEqual(PostRef.parse("/tx/\(txHash)?headless=1", defaultChainId: 1), PostRef(chainId: 1, txHash: txHash))
        XCTAssertEqual(PostRef.parse("https://xueni.xyz/ethereum/tx/\(txHash)/2", defaultChainId: 167_000), PostRef(chainId: 1, txHash: txHash, eventIndex: 2))
    }

    func testFormatting() {
        XCTAssertEqual(PostRef(chainId: 1, txHash: txHash).formatted(currentChainId: 1), txHash)
        XCTAssertEqual(PostRef(chainId: 167_000, txHash: txHash, eventIndex: 1).formatted(currentChainId: 1), "taiko:\(txHash)/1")
        XCTAssertEqual(PostRef(chainId: 1, txHash: txHash).webURL().absoluteString, "https://xueni.xyz/ethereum/tx/\(txHash)/0")
    }

    func testInArticleReferencesAndImages() {
        let md = "See [the chest](\(txHash)) and [](\(txHash)/1), not [this](https://x.y) or ![pic](eth:\(txHash)) twice ![pic](eth:\(txHash))."
        let refs = PostRefs.references(in: md)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].text, "the chest")
        XCTAssertEqual(refs[1].ref.eventIndex, 1)
        XCTAssertEqual(PostRefs.imageRefs(in: md), [txHash])
    }
}

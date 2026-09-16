import Foundation
import XCTest
@testable import XueniKit

final class MarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndBreaks() {
        let blocks = Markdown.parse("# 冬至\n\nFirst line\nsecond line\n\n## Two ##\n\nTail\n===\n")
        XCTAssertEqual(blocks, [
            .heading(level: 1, content: [.text("冬至")]),
            .paragraph([.text("First line"), .lineBreak, .text("second line")]),
            .heading(level: 2, content: [.text("Two")]),
            .heading(level: 1, content: [.text("Tail")]),
        ])
    }

    func testEmphasisCodeAndEscapes() {
        XCTAssertEqual(InlineParser.parse("**bold** and *it* and ***both*** and ~~gone~~ and `co*de` and \\*not\\*"), [
            .strong([.text("bold")]), .text(" and "), .emphasis([.text("it")]), .text(" and "),
            .strong([.emphasis([.text("both")])]), .text(" and "), .strikethrough([.text("gone")]),
            .text(" and "), .code("co*de"), .text(" and *not*"),
        ])
        XCTAssertEqual(InlineParser.parse("snake_case_name and _em_"), [.text("snake_case_name and "), .emphasis([.text("em")])])
        XCTAssertEqual(InlineParser.parse("a * b * c"), [.text("a * b * c")])
        XCTAssertEqual(InlineParser.parse("``a`b``"), [.code("a`b")])
    }

    func testLinksImagesAndReferences() {
        let hash = "0x41663fee6dd678632e23c8365076b466603b0d0694925e13b0d0d2007bec7844"
        let inlines = InlineParser.parse("[chest](\(hash)/1) [x](https://a.b/c \"t\") ![alt \"q\"](eth:\(hash)) <https://d.e> https://f.g/h. [js](javascript:alert(1))")
        XCTAssertEqual(inlines[0], .link(text: [.text("chest")], url: "\(hash)/1"))
        XCTAssertEqual(inlines[2], .link(text: [.text("x")], url: "https://a.b/c"))
        XCTAssertEqual(inlines[4], .image(alt: "alt \"q\"", url: "eth:\(hash)"))
        XCTAssertEqual(inlines[6], .link(text: [.text("https://d.e")], url: "https://d.e"))
        XCTAssertEqual(inlines[8], .link(text: [.text("https://f.g/h")], url: "https://f.g/h"))
        XCTAssertEqual(LinkTarget.of("\(hash)/1"), .post(txHash: hash, eventIndex: 1))
        XCTAssertEqual(LinkTarget.of("https://a.b/c"), .external(URL(string: "https://a.b/c")!))
        XCTAssertEqual(LinkTarget.of("javascript:alert(1)"), .none)
        XCTAssertEqual(LinkTarget.of("data:text/html,x"), .none)
        XCTAssertEqual(ImageSource.of("eth:\(hash)"), .chain(txHash: hash))
        XCTAssertEqual(ImageSource.of("eth:0x12"), .none)
        XCTAssertEqual(ImageSource.of("javascript:x"), .none)
    }

    func testRawHTMLIsDroppedAndEntitiesRead() {
        XCTAssertEqual(InlineParser.parse("a <b>bold</b> &amp; <img src=x onerror=alert(1)> &#20908; &lt;"), [.text("a bold & 冬 <")])
        XCTAssertEqual(Markdown.parse("one\r\ntwo\r\n"), [.paragraph([.text("one"), .lineBreak, .text("two")])])
        XCTAssertEqual(InlineParser.parse("2 < 3 and a<b"), [.text("2 < 3 and a<b")])
    }

    func testListsNestedAndOrdered() {
        let blocks = Markdown.parse("- one\n- two\n  - inner\n\n3. three\n4. four\n   continued")
        guard case .list(let ordered, _, let items) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1], [.paragraph([.text("two")]), .list(ordered: false, start: 1, items: [[.paragraph([.text("inner")])]])])
        guard case .list(let ordered2, let start, let items2) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertTrue(ordered2)
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items2[1], [.paragraph([.text("four"), .lineBreak, .text("continued")])])
    }

    func testBlockquoteCodeRuleAndTable() {
        let blocks = Markdown.parse("> quoted\n> more\n\n```js\nlet x = 1;\n```\n\n---\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n| `p|q` | 4 |\n\n    indented\n")
        XCTAssertEqual(blocks[0], .blockquote([.paragraph([.text("quoted"), .lineBreak, .text("more")])]))
        XCTAssertEqual(blocks[1], .codeBlock(language: "js", code: "let x = 1;"))
        XCTAssertEqual(blocks[2], .thematicBreak)
        XCTAssertEqual(blocks[3], .table(header: [[.text("a")], [.text("b")]], alignments: [.none, .center], rows: [[[.text("1")], [.text("2")]], [[.code("p|q")], [.text("4")]]]))
        XCTAssertEqual(blocks[4], .codeBlock(language: nil, code: "indented"))
    }

    func testARuleInsideTheBodyAndAnUnclosedFence() {
        let blocks = Markdown.parse("正文。\n\n---\n\nA rule inside the body.\n\n```\nopen")
        XCTAssertEqual(blocks, [.paragraph([.text("正文。")]), .thematicBreak, .paragraph([.text("A rule inside the body.")]), .codeBlock(language: nil, code: "open")])
    }

    func testExcerptAndPlainText() {
        let md = "# Title\n\nSome **bold** text with a [link](https://x) and ![pic](eth:0x1)\n\n```\ncode\n```\n\n- item one\n- item two"
        XCTAssertEqual(Markdown.excerpt(md, maxChars: 30), "Title Some bold text with a…")
        XCTAssertEqual(Markdown.excerpt(md), "Title Some bold text with a link and item one item two")
        XCTAssertEqual(Markdown.excerpt("short"), "short")
        XCTAssertEqual(Markdown.excerpt(""), "")
    }
}

final class IdenticonTests: XCTestCase {
    func testMatchesBlo() {
        // Pinned from `bloImage(address)` in the web app's own dependency.
        let cases: [(String, [UInt8], (Int, Int, Int))] = [
            ("0x8a1f3b52c9e44e1a9b1f0d2c7a44e0b1d2e3f4a5", [0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 1, 1, 2, 0, 0, 0, 1, 0, 1, 1], (65, 29, 52)),
            ("0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d9", [1, 0, 1, 2, 2, 0, 0, 0, 1, 0, 1, 0, 0, 1, 2, 1, 1, 0, 0, 0, 2, 1, 2, 2, 0, 0, 2, 0, 1, 1, 2, 1], (45, 35, 48)),
            ("0x327fa3369B1D1D42120d84bc407e5865ECa7c458", [2, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 2, 0, 1, 0, 0, 1, 0], (81, 66, 35)),
        ]
        for (address, half, lightness) in cases {
            let icon = Identicon.make(for: address)
            var mirrored = [UInt8](repeating: 0, count: 64)
            for i in 0..<32 {
                let x = i & 3, y = i >> 2
                mirrored[y * 8 + x] = half[i]
                mirrored[y * 8 + 7 - x] = half[i]
            }
            XCTAssertEqual(icon.cells, mirrored, address)
            var rng = SeededRandom(seed: address.lowercased())
            let c = rng.color(), b = rng.color(), s = rng.color()
            XCTAssertEqual(Int((b.lightness * 100).rounded()), lightness.0, address)
            XCTAssertEqual(Int((c.lightness * 100).rounded()), lightness.1, address)
            XCTAssertEqual(Int((s.lightness * 100).rounded()), lightness.2, address)
            XCTAssertGreaterThanOrEqual(abs(icon.color - icon.background), 0.35)
        }
        XCTAssertEqual(Identicon.make(for: alice), Identicon.make(for: alice.uppercased().replacingOccurrences(of: "0X", with: "0x")))
    }
}

final class ArchiveTests: XCTestCase {
    let sample = """
    {
      "xueni": { "archive": 2 },
      "exportedAt": "2026-09-15T12:00:00.000Z",
      "contract": "0x0000003CE1a46C7Fbb02B9E1a0A4709AD9cb15d9",
      "scope": { "kind": "author", "address": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
      "posts": [
        { "chainId": 1, "txHash": "0x1111111111111111111111111111111111111111111111111111111111111111", "eventIndex": 0,
          "author": "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "index": 0, "block": 25985120, "prevBlock": 0, "logIndex": 12,
          "ts": 1757000000, "title": "A letter", "text": "---\\ntags: letters home\\n---\\n\\nXiaoman", "compressedBytes": 1432, "hook": null },
        { "chainId": 99, "txHash": "0x2222222222222222222222222222222222222222222222222222222222222222", "author": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "text": "x" },
        { "chainId": 167000, "txHash": "not a hash", "author": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "text": "x" }
      ],
      "images": [ { "chainId": 1, "txHash": "0x3333333333333333333333333333333333333333333333333333333333333333", "mime": "image/webp", "base64": "UklGRg==" } ],
      "authors": [ { "chainId": 1, "address": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "head": 25985120, "complete": true } ]
    }
    """

    func testParseKeepsTheGoodHalf() {
        let reading = Archive.parse(Data(sample.utf8))
        XCTAssertEqual(reading.problems, [.droppedPosts(2)])
        let doc = reading.document!
        XCTAssertEqual(doc.posts.count, 1)
        XCTAssertEqual(doc.posts[0].author, alice)
        XCTAssertEqual(doc.posts[0].row.block, 25_985_120)
        XCTAssertEqual(doc.posts[0].row.ts, 1_757_000_000)
        XCTAssertEqual(Document.parse(doc.posts[0].text).tags, ["letters home"])
        XCTAssertEqual(doc.images[0].bytes, [0x52, 0x49, 0x46, 0x46])
        XCTAssertEqual(doc.authors[0].complete, true)
        XCTAssertEqual(doc.scope, .author(alice))
        XCTAssertEqual(reading.summary, [ArchiveChainSummary(chainId: 1, posts: 1, images: 1, completeAuthors: 1)])
    }

    func testRefusals() {
        XCTAssertEqual(Archive.parse(Data("nope".utf8)).problems, [.notJSON])
        XCTAssertEqual(Archive.parse(Data("{}".utf8)).problems, [.notArchive])
        XCTAssertEqual(Archive.parse(Data("{\"xueni\":{\"archive\":1}}".utf8)).problems, [.wrongVersion(1)])
        XCTAssertEqual(Archive.parse(Data("{\"xueni\":{\"archive\":2},\"contract\":\"0x000000AE2f2249c497cfc5F262dd1491634C361C\"}".utf8)).problems, [.wrongContract("0x000000AE2f2249c497cfc5F262dd1491634C361C")])
        XCTAssertEqual(Archive.parse(Data("{\"xueni\":{\"archive\":2}}".utf8)).problems, [.empty])
    }

    func testRoundTrip() throws {
        let post = ArchivePost(chainId: 167_000, txHash: "0x" + String(repeating: "ab", count: 32), eventIndex: 1, author: bob, index: 3, block: 11_500_000, prevBlock: 11_400_000, logIndex: nil, ts: nil, title: "多个", text: "# 冬至\n", compressedBytes: 40, hook: Chains.multiHookAddress)
        let doc = ArchiveDocument(scope: .device, posts: [post], images: [ArchiveImage(chainId: 167_000, txHash: "0x" + String(repeating: "cd", count: 32), bytes: [1, 2, 3])], authors: [])
        let data = try Archive.serialize(doc)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"archive\" : 2"))
        let back = Archive.parse(data)
        XCTAssertEqual(back.problems, [])
        XCTAssertEqual(back.document?.posts, [post])
        XCTAssertEqual(back.document?.images.first?.bytes, [1, 2, 3])
        XCTAssertEqual(back.document?.scope.kind, "browser")
        XCTAssertTrue(Archive.fileName(scope: .author(bob), now: Date(timeIntervalSince1970: 0)).hasPrefix("xueni-archive-bbbbbbbb-1970-01-01"))
        XCTAssertTrue(Archive.fileName(scope: .device, now: Date(timeIntervalSince1970: 0)).hasSuffix(".xueni.json"))
    }
}

final class SettingsFileTests: XCTestCase {
    func testParseTheWebAppsFile() {
        let text = """
        {"xueni":{"settings":1},"exportedAt":"2026-09-15T12:00:00.000Z",
         "rpcs":{"1":["https://eth.drpc.org","https://rpc.mevblocker.io"],"167000":["https://my.node/x", 7],"5":["https://a"]},
         "rescanDelayMinutes":5,"publishChain":167000,"lang":"zh","theme":null,"log":false,
         "following":["0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","nope","0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}
        """
        let reading = SettingsFile.parse(Data(text.utf8))
        XCTAssertEqual(reading.problems, [.droppedEndpoints(chainId: 167_000, count: 1), .unknownChain("5"), .followingDropped(1)])
        XCTAssertEqual(reading.patch.rpcs, [1: Chains.ethereum.defaultRPCs, 167_000: ["https://my.node/x"]])
        XCTAssertEqual(reading.patch.rescanDelayMinutes, 5)
        XCTAssertEqual(reading.patch.lang, .zh)
        XCTAssertEqual(reading.patch.following, [alice])
        XCTAssertEqual(reading.patch.publishChain, .some(167_000))
        XCTAssertEqual(reading.patch.theme, .some(nil))
        XCTAssertEqual(reading.patch.log, false)
        XCTAssertTrue(reading.summary.contains(.defaultEndpoints(chainId: 1)))
        XCTAssertTrue(reading.summary.contains(.customEndpoints(chainId: 167_000, count: 1)))
    }

    func testRefusalsAndRoundTrip() throws {
        XCTAssertEqual(SettingsFile.parse(Data("[]".utf8)).problems, [.notObject])
        XCTAssertEqual(SettingsFile.parse(Data("{}".utf8)).problems, [.notXueni])
        XCTAssertEqual(SettingsFile.parse(Data("{\"xueni\":{\"settings\":2}}".utf8)).problems, [.badFormat(2)])
        XCTAssertEqual(SettingsFile.parse(Data("{\"xueni\":{\"settings\":1}}".utf8)).problems, [.nothing])
        let snapshot = SettingsSnapshot(rpcs: [1: ["https://a"], 167_000: Chains.taiko.defaultRPCs], rescanDelayMinutes: 0, lang: .en, following: [bob], publishChain: nil, theme: "dark", log: true)
        let data = try SettingsFile.serialize(snapshot)
        let back = SettingsFile.parse(data)
        XCTAssertEqual(back.problems, [])
        XCTAssertEqual(back.patch.rpcs, snapshot.rpcs)
        XCTAssertEqual(back.patch.rescanDelayMinutes, 0)
        XCTAssertEqual(back.patch.lang, .en)
        XCTAssertEqual(back.patch.following, [bob])
        XCTAssertEqual(back.patch.theme, .some("dark"))
        XCTAssertEqual(back.patch.log, true)
        XCTAssertEqual(back.patch.publishChain, .some(nil))
    }
}

final class SearchAndFormatTests: XCTestCase {
    func testSearch() {
        XCTAssertEqual(Search.match(title: "Winter by the sea", tags: [], markdown: "", query: "winter")?.location, .title)
        XCTAssertEqual(Search.match(title: "", tags: ["letters home"], markdown: "", query: "home")?.snippet, "letters home")
        let body = String(repeating: "前面的文字。", count: 40) + "香樟木箱" + String(repeating: "后面的文字。", count: 40)
        let hit = Search.match(title: "", tags: [], markdown: body, query: Search.normalize("香樟"))
        XCTAssertEqual(hit?.location, .body)
        XCTAssertTrue(hit!.snippet.contains("香樟木箱"))
        XCTAssertTrue(hit!.snippet.hasPrefix("…"))
        XCTAssertNil(Search.match(title: "a", tags: [], markdown: "b", query: "z"))
        XCTAssertEqual(Search.highlight("Winter and winter", query: "winter").map { $0.hit }, [true, false, true])
        XCTAssertEqual(Search.highlight("nothing", query: "").count, 1)
    }

    func testFormat() {
        XCTAssertEqual(Format.shortAddress(alice), "0xaaaa....aaaa")
        XCTAssertEqual(Format.shortAddress("0x12"), "0x12")
        XCTAssertEqual(Format.grouped(UInt64(25_980_697)), "25,980,697")
        XCTAssertEqual(Format.grouped(UInt64(999)), "999")
        XCTAssertEqual(Format.grouped(UInt64(0)), "0")
        XCTAssertEqual(Format.bytes(999), "999 B")
        XCTAssertEqual(Format.bytes(1432), "1.4 KB")
        XCTAssertEqual(Format.bytes(43_264), "42.3 KB")
        XCTAssertEqual(Format.bytes(3 * 1024 * 1024), "3.00 MB")
        XCTAssertEqual(Format.ordinal(2), 3)
    }

    func testStringsCarryTheSameKeysInBothLanguages() {
        XCTAssertEqual(Set(Strings.en.keys), Set(Strings.zh.keys))
        let en = Strings(.en)
        let zh = Strings(.zh)
        XCTAssertEqual(en.t("feed.readFailed", ["chain": "Taiko", "reason": "x"]), "Taiko could not be read: x")
        XCTAssertEqual(zh.t("feed.readFailed", ["chain": "Taiko", "reason": "x"]), "Taiko 读取失败：x")
        XCTAssertEqual(en.joinChains([1, 167_000]), "Ethereum and Taiko")
        XCTAssertEqual(zh.joinChains([1, 167_000]), "Ethereum和Taiko")
        XCTAssertEqual(en.count(1, "common.post", "common.posts"), "1 post")
        XCTAssertEqual(en.count(2, "common.post", "common.posts"), "2 posts")
        XCTAssertEqual(zh.count(2, "common.post", "common.posts"), "2 篇")
        XCTAssertEqual(en.t("missing.key"), "missing.key")
        for (key, value) in Strings.en {
            let slots = value.components(separatedBy: "{").dropFirst().compactMap { $0.split(separator: "}").first }
            let zhSlots = Strings.zh[key]!.components(separatedBy: "{").dropFirst().compactMap { $0.split(separator: "}").first }
            XCTAssertEqual(Set(slots), Set(zhSlots), key)
        }
    }
}

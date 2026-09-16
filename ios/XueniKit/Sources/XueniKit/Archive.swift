// Archive.swift — everything this device has read, as one file.
//
// The spec's third layer of permanence (§9.1): one plain JSON document
// holding the exact stored text of every post, the images those posts
// refer to, and a note of which author lists were walked to their end.
// The web app and the command-line tool write the same format
// (`.xueni.json`, format 2), so a bundle taken anywhere seeds the phone,
// and the other way round.
//
// Deliberately NOT the app: a bundle is data, readable by anything that can
// read JSON, and carries no code.

import Foundation

public struct ArchivePost: Codable, Sendable, Equatable {
    public var chainId: Int
    public var txHash: String
    public var eventIndex: Int
    public var author: String
    public var index: Int
    public var block: Int
    public var prevBlock: Int
    public var logIndex: Int?
    public var ts: Int?
    public var title: String
    /// The exact decompressed document.
    public var text: String
    public var compressedBytes: Int
    public var hook: String?

    public init(chainId: Int, txHash: String, eventIndex: Int, author: String, index: Int, block: Int, prevBlock: Int, logIndex: Int?, ts: Int?, title: String, text: String, compressedBytes: Int, hook: String?) {
        self.chainId = chainId
        self.txHash = txHash.lowercased()
        self.eventIndex = eventIndex
        self.author = author.lowercased()
        self.index = index
        self.block = block
        self.prevBlock = prevBlock
        self.logIndex = logIndex
        self.ts = ts
        self.title = title
        self.text = text
        self.compressedBytes = compressedBytes
        self.hook = hook?.lowercased()
    }

    /// The row this record proves.
    public var row: PostRow {
        PostRow(chainId: chainId, author: author, index: UInt64(max(0, index)), block: UInt64(max(0, block)), prevBlock: UInt64(max(0, prevBlock)), title: title, txHash: txHash, eventIndex: eventIndex, logIndex: logIndex, ts: ts, hook: hook)
    }
}

public struct ArchiveImage: Codable, Sendable, Equatable {
    public var chainId: Int
    public var txHash: String
    public var mime: String
    public var base64: String

    public init(chainId: Int, txHash: String, bytes: [UInt8]) {
        self.chainId = chainId
        self.txHash = txHash.lowercased()
        self.mime = Archive.imageMIME
        self.base64 = Data(bytes).base64EncodedString()
    }

    public var bytes: [UInt8]? {
        Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]).map(Array.init)
    }
}

public struct ArchiveAuthor: Codable, Sendable, Equatable {
    public var chainId: Int
    public var address: String
    public var head: Int
    public var complete: Bool

    public init(chainId: Int, address: String, head: Int, complete: Bool) {
        self.chainId = chainId
        self.address = address.lowercased()
        self.head = head
        self.complete = complete
    }
}

public struct ArchiveScope: Codable, Sendable, Equatable {
    public var kind: String
    public var address: String?

    public static let device = ArchiveScope(kind: "browser", address: nil)
    public static func author(_ address: String) -> ArchiveScope { ArchiveScope(kind: "author", address: address.lowercased()) }
}

public struct ArchiveDocument: Codable, Sendable, Equatable {
    public struct Marker: Codable, Sendable, Equatable {
        public var archive: Int
    }

    public var xueni: Marker
    public var exportedAt: String
    public var contract: String
    public var scope: ArchiveScope
    public var posts: [ArchivePost]
    public var images: [ArchiveImage]
    public var authors: [ArchiveAuthor]

    public init(scope: ArchiveScope, posts: [ArchivePost], images: [ArchiveImage], authors: [ArchiveAuthor], now: Date = Date()) {
        self.xueni = Marker(archive: Archive.format)
        self.exportedAt = Archive.isoFormatter.string(from: now)
        self.contract = Chains.xueniAddress
        self.scope = scope
        self.posts = posts
        self.images = images
        self.authors = authors
    }
}

/// What reading a bundle found: the usable part, and what was wrong.
public struct ArchiveReading: Sendable {
    public var document: ArchiveDocument?
    /// Problem codes, for the interface to say in its language.
    public var problems: [ArchiveProblem]
    /// Per-chain counts of what would be imported.
    public var summary: [ArchiveChainSummary]
}

public enum ArchiveProblem: Sendable, Equatable {
    case notJSON
    case notArchive
    case wrongVersion(Int)
    case wrongContract(String)
    case droppedPosts(Int)
    case droppedImages(Int)
    case empty
}

public struct ArchiveChainSummary: Sendable, Equatable {
    public var chainId: Int
    public var posts: Int
    public var images: Int
    public var completeAuthors: Int
}

public enum Archive {
    /// The format version, as `xueni.archive`. Bumping it is breaking the file.
    public static let format = 2
    /// Every image on chain is WebP: the writers only ever produce that.
    public static let imageMIME = "image/webp"

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The name a bundle is offered under.
    public static func fileName(scope: ArchiveScope, now: Date = Date()) -> String {
        let day = String(isoFormatter.string(from: now).prefix(10))
        let who = scope.kind == "author" ? "-" + String((scope.address ?? "").dropFirst(2).prefix(8)) : ""
        return "xueni-archive\(who)-\(day).xueni.json"
    }

    public static func serialize(_ doc: ArchiveDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }

    /// Read a bundle and say what is in it, without applying anything. A
    /// file that is half broken is worth importing the good half of.
    public static func parse(_ data: Data) -> ArchiveReading {
        let raw: JSON
        do {
            raw = try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            return ArchiveReading(document: nil, problems: [.notJSON], summary: [])
        }
        guard let object = raw.object else { return ArchiveReading(document: nil, problems: [.notArchive], summary: []) }
        guard let versionNumber = object["xueni"]?["archive"], case .number(let version) = versionNumber else {
            return ArchiveReading(document: nil, problems: [.notArchive], summary: [])
        }
        guard Int(version) == format else { return ArchiveReading(document: nil, problems: [.wrongVersion(Int(version))], summary: []) }
        if let contract = object["contract"]?.string, contract.lowercased() != Chains.xueniAddress {
            return ArchiveReading(document: nil, problems: [.wrongContract(contract)], summary: [])
        }

        var problems: [ArchiveProblem] = []
        let rawPosts = object["posts"]?.array ?? []
        let posts = rawPosts.compactMap(post(from:))
        if posts.count < rawPosts.count { problems.append(.droppedPosts(rawPosts.count - posts.count)) }
        let rawImages = object["images"]?.array ?? []
        let images = rawImages.compactMap(image(from:))
        if images.count < rawImages.count { problems.append(.droppedImages(rawImages.count - images.count)) }
        let authors = (object["authors"]?.array ?? []).compactMap(author(from:))
        if posts.isEmpty { problems.append(.empty) }

        let scope = ArchiveScope(kind: object["scope"]?["kind"]?.string ?? "browser", address: object["scope"]?["address"]?.string?.lowercased())
        var doc = ArchiveDocument(scope: scope, posts: posts, images: images, authors: authors)
        doc.exportedAt = object["exportedAt"]?.string ?? doc.exportedAt

        let chainIds = Set(posts.map { $0.chainId }).sorted()
        let summary = chainIds.map { id in
            ArchiveChainSummary(
                chainId: id,
                posts: posts.filter { $0.chainId == id }.count,
                images: images.filter { $0.chainId == id }.count,
                completeAuthors: authors.filter { $0.chainId == id && $0.complete }.count
            )
        }
        return ArchiveReading(document: doc, problems: problems, summary: summary)
    }

    private static func int(_ json: JSON?) -> Int? {
        guard let json = json else { return nil }
        if case .number(let n) = json, n.isFinite { return Int(n) }
        if case .string(let s) = json { return Int(s) }
        return nil
    }

    private static func post(from json: JSON) -> ArchivePost? {
        guard let chainId = int(json["chainId"]), Chains.isKnown(chainId) else { return nil }
        guard let txHash = json["txHash"]?.string, Hex.isHash(txHash) else { return nil }
        guard let author = json["author"]?.string, Hex.isAddress(author) else { return nil }
        guard let text = json["text"]?.string else { return nil }
        let hook = json["hook"]?.string.flatMap { Hex.isAddress($0) ? $0.lowercased() : nil }
        return ArchivePost(
            chainId: chainId,
            txHash: txHash,
            eventIndex: int(json["eventIndex"]) ?? 0,
            author: author,
            index: int(json["index"]) ?? 0,
            block: int(json["block"]) ?? 0,
            prevBlock: int(json["prevBlock"]) ?? 0,
            logIndex: int(json["logIndex"]),
            ts: int(json["ts"]),
            title: json["title"]?.string ?? "",
            text: text,
            compressedBytes: int(json["compressedBytes"]) ?? 0,
            hook: hook
        )
    }

    private static func image(from json: JSON) -> ArchiveImage? {
        guard let chainId = int(json["chainId"]), Chains.isKnown(chainId) else { return nil }
        guard let txHash = json["txHash"]?.string, Hex.isHash(txHash) else { return nil }
        guard let base64 = json["base64"]?.string else { return nil }
        var image = ArchiveImage(chainId: chainId, txHash: txHash, bytes: [])
        image.base64 = base64
        image.mime = json["mime"]?.string ?? imageMIME
        return image
    }

    private static func author(from json: JSON) -> ArchiveAuthor? {
        guard let chainId = int(json["chainId"]), Chains.isKnown(chainId) else { return nil }
        guard let address = json["address"]?.string, Hex.isAddress(address) else { return nil }
        var complete = false
        if case .bool(let b)? = json["complete"] { complete = b }
        return ArchiveAuthor(chainId: chainId, address: address, head: int(json["head"]) ?? 0, complete: complete)
    }
}

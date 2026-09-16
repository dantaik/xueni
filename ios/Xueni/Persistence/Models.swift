// Models.swift — what the phone keeps, in two databases.
//
// The CHAIN CACHE is what has been read from the chains: post rows, the
// documents behind them, the images they refer to, and the block ranges
// each chain has been scanned over. Every record is immutable on chain, so
// nothing here ever expires; and every record can be read again, so the
// whole store can be thrown away without losing anything of the reader's.
//
// The READER STORE is what is the reader's own and nowhere else: the
// authors they follow and the letter they are writing. It is small, and it
// is the one the settings file and the archive exist to carry.
//
// The two live in separate SQLite files (see Containers.swift): a cache
// that can be cleared, and a store that must not be.

import Foundation
import SwiftData
import XueniKit

// MARK: - The chain cache

@Model
final class CachedPost {
    /// `chainId:txHash:eventIndex` — a post's identity across chains.
    @Attribute(.unique) var key: String
    var chainId: Int
    var author: String
    var index: Int
    var block: Int
    var prevBlock: Int
    var title: String
    var txHash: String
    var eventIndex: Int
    var logIndex: Int?
    var ts: Int?
    var hook: String?

    init(row: PostRow) {
        key = row.id
        chainId = row.chainId
        author = row.author
        index = Int(row.index)
        block = Int(row.block)
        prevBlock = Int(row.prevBlock)
        title = row.title
        txHash = row.txHash
        eventIndex = row.eventIndex
        logIndex = row.logIndex
        ts = row.ts
        hook = row.hook
    }

    static func key(chainId: Int, txHash: String, eventIndex: Int) -> String {
        "\(chainId):\(txHash.lowercased()):\(eventIndex)"
    }

    var row: PostRow {
        PostRow(chainId: chainId, author: author, index: UInt64(max(0, index)), block: UInt64(max(0, block)), prevBlock: UInt64(max(0, prevBlock)), title: title, txHash: txHash, eventIndex: eventIndex, logIndex: logIndex, ts: ts, hook: hook)
    }
}

@Model
final class CachedBody {
    /// `chainId:txHash`.
    @Attribute(.unique) var key: String
    var chainId: Int
    var txHash: String
    /// The exact document the chain holds.
    var text: String
    var compressedBytes: Int
    /// Which of the three calls carried the post.
    var form: String
    var hook: String?
    var hookDataHex: String
    var relayedAuthor: String?
    var relayedDeadline: String?
    var relayedSignatureHex: String?
    var sender: String?
    var readAt: Date

    init(chainId: Int, txHash: String, text: String, compressedBytes: Int, form: String, hook: String?, hookDataHex: String, relayedAuthor: String?, relayedDeadline: String?, relayedSignatureHex: String?, sender: String?) {
        key = CachedBody.key(chainId: chainId, txHash: txHash)
        self.chainId = chainId
        self.txHash = txHash.lowercased()
        self.text = text
        self.compressedBytes = compressedBytes
        self.form = form
        self.hook = hook
        self.hookDataHex = hookDataHex
        self.relayedAuthor = relayedAuthor
        self.relayedDeadline = relayedDeadline
        self.relayedSignatureHex = relayedSignatureHex
        self.sender = sender
        readAt = Date()
    }

    static func key(chainId: Int, txHash: String) -> String {
        "\(chainId):\(txHash.lowercased())"
    }
}

@Model
final class CachedImage {
    @Attribute(.unique) var key: String
    var chainId: Int
    var txHash: String
    @Attribute(.externalStorage) var bytes: Data

    init(chainId: Int, txHash: String, bytes: Data) {
        key = CachedBody.key(chainId: chainId, txHash: txHash)
        self.chainId = chainId
        self.txHash = txHash.lowercased()
        self.bytes = bytes
    }
}

/// One block range read in full: for every author (`kind` = feed) or for
/// one author's own single-block reads (`kind` = author).
@Model
final class ScanRange {
    var chainId: Int
    var kind: String
    var author: String
    var from: Int
    var to: Int

    init(chainId: Int, kind: String, author: String, from: Int, to: Int) {
        self.chainId = chainId
        self.kind = kind
        self.author = author
        self.from = from
        self.to = to
    }
}

/// Where a completed scan got to: the chain head for the feed, the author's
/// `latestBlock` for a walk.
@Model
final class ScanHead {
    @Attribute(.unique) var key: String
    var chainId: Int
    var kind: String
    var author: String
    var head: Int

    init(chainId: Int, kind: String, author: String, head: Int) {
        key = ScanHead.key(chainId: chainId, kind: kind, author: author)
        self.chainId = chainId
        self.kind = kind
        self.author = author
        self.head = head
    }

    static func key(chainId: Int, kind: String, author: String) -> String {
        "\(chainId):\(kind):\(author)"
    }
}

// MARK: - The reader's own

@Model
final class FollowedAuthor {
    @Attribute(.unique) var address: String
    var addedAt: Date

    init(address: String) {
        self.address = address.lowercased()
        addedAt = Date()
    }
}

/// The one draft: this is a place to write a letter, not a queue.
@Model
final class Draft {
    @Attribute(.unique) var key: String
    var title: String
    var tags: String
    var markdown: String
    var lang: String
    var re: String
    var supersedes: String
    var prev: String
    var series: String
    var part: String
    var updatedAt: Date

    init() {
        key = "current"
        title = ""
        tags = ""
        markdown = ""
        lang = ""
        re = ""
        supersedes = ""
        prev = ""
        series = ""
        part = ""
        updatedAt = Date()
    }

    var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var meta: [String: String] {
        var out: [String: String] = [:]
        for (key, value) in [("lang", lang), ("re", re), ("supersedes", supersedes), ("prev", prev), ("series", series), ("part", part)] {
            let v = value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { out[key] = v }
        }
        return out
    }

    /// The document as the chain would hold it.
    var document: String {
        Document.build(markdown: markdown, tags: tagList, meta: meta)
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty && markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tagList.isEmpty && meta.isEmpty
    }
}

// ArchiveBuilder.swift — everything this phone has read, as one file.
//
// The spec's third layer of permanence: one plain JSON document holding
// the exact stored text of every post, the images those posts refer to,
// and which author lists were walked to their end. The web app and the
// command-line tool write the same format, so a bundle taken anywhere
// seeds the phone and the other way round.

import Foundation
import XueniKit

@MainActor
enum ArchiveBuilder {
    /// Every post whose document this phone holds, with the images it refers to.
    static func everything(hub: ReaderHub) -> ArchiveDocument {
        var posts: [ArchivePost] = []
        var images: [ArchiveImage] = []
        var seen = Set<String>()
        for body in hub.cache.allBodies() {
            guard let reader = hub.reader(body.chainId), let row = reader.store.knownPost(txHash: body.txHash, eventIndex: 0) else { continue }
            posts.append(record(row, text: body.text, compressedBytes: body.compressedBytes, hook: row.hook ?? body.hook))
            for hash in PostRefs.imageRefs(in: Document.parse(body.text).markdown) {
                let key = "\(body.chainId):\(hash)"
                guard !seen.contains(key), let data = hub.cache.image(chainId: body.chainId, txHash: hash) else { continue }
                seen.insert(key)
                images.append(ArchiveImage(chainId: body.chainId, txHash: hash, bytes: Array(data)))
            }
        }
        return ArchiveDocument(scope: .device, posts: posts, images: images, authors: [])
    }

    /// One author's complete output: the walk is driven to their first
    /// post on every chain first, so the bundle can say `complete: true`.
    static func author(hub: ReaderHub, address: String, progress: @MainActor (Int, Int) -> Void) async -> ArchiveDocument {
        let who = address.lowercased()
        var posts: [ArchivePost] = []
        var images: [ArchiveImage] = []
        var authors: [ArchiveAuthor] = []
        var seen = Set<String>()
        var walks: [(ChainReader, [PostRow], Bool)] = []
        for reader in hub.readers {
            let list = reader.authorList(who)
            await list.refresh()
            var guardCount = 0
            while list.snapshot.hasMore, list.snapshot.error == nil, guardCount < 500 {
                await list.loadMore()
                guardCount += 1
            }
            walks.append((reader, list.snapshot.rows, !list.snapshot.hasMore && list.snapshot.error == nil))
        }
        let total = walks.reduce(0) { $0 + $1.1.count }
        var done = 0
        for (reader, rows, complete) in walks {
            for row in rows {
                done += 1
                progress(done, total)
                guard let body = try? await reader.loadBody(row.txHash) else { continue }
                posts.append(record(row, text: body.text, compressedBytes: body.compressedBytes, hook: row.hook ?? body.hook))
                for hash in PostRefs.imageRefs(in: body.markdown) {
                    let key = "\(reader.chainId):\(hash)"
                    guard !seen.contains(key), let data = try? await reader.loadImage(hash) else { continue }
                    seen.insert(key)
                    images.append(ArchiveImage(chainId: reader.chainId, txHash: hash, bytes: Array(data)))
                }
            }
            authors.append(ArchiveAuthor(chainId: reader.chainId, address: who, head: Int(rows.map { $0.block }.max() ?? 0), complete: complete))
        }
        return ArchiveDocument(scope: .author(who), posts: posts, images: images, authors: authors)
    }

    private static func record(_ row: PostRow, text: String, compressedBytes: Int, hook: String?) -> ArchivePost {
        ArchivePost(chainId: row.chainId, txHash: row.txHash, eventIndex: row.eventIndex, author: row.author, index: Int(row.index), block: Int(row.block), prevBlock: Int(row.prevBlock), logIndex: row.logIndex, ts: row.ts, title: row.title, text: text, compressedBytes: compressedBytes, hook: hook)
    }

    static func write(_ doc: ArchiveDocument) throws -> URL {
        try Files.temporary(named: Archive.fileName(scope: doc.scope), data: Archive.serialize(doc))
    }

    /// Put a bundle into this phone. Nothing already here is overwritten:
    /// what a post says is fixed by the transaction that carries it. Each
    /// row proves its own block for its own author, and a complete author
    /// proves their whole list; nothing proves anything about the feed.
    static func apply(_ doc: ArchiveDocument, hub: ReaderHub) -> (posts: Int, skipped: Int, images: Int) {
        var written = 0
        var skipped = 0
        var imagesWritten = 0
        for post in doc.posts {
            guard let reader = hub.reader(post.chainId) else { skipped += 1; continue }
            if hub.cache.body(chainId: post.chainId, txHash: post.txHash) != nil {
                skipped += 1
            } else {
                hub.cache.saveArchivedBody(post)
                written += 1
            }
            let row = post.row
            reader.store.rememberPosts([row])
            reader.store.rememberAuthorBlock(row.author, row.block)
        }
        for image in doc.images {
            guard hub.reader(image.chainId) != nil, let bytes = image.bytes else { continue }
            if hub.cache.image(chainId: image.chainId, txHash: image.txHash) == nil {
                hub.cache.saveImage(chainId: image.chainId, txHash: image.txHash, bytes: Data(bytes))
                imagesWritten += 1
            }
        }
        for author in doc.authors where author.complete {
            hub.reader(author.chainId)?.store.setAuthorScanHead(author.address, UInt64(max(0, author.head)))
        }
        return (written, skipped, imagesWritten)
    }
}

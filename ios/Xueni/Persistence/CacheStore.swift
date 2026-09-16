// CacheStore.swift — the chain cache, read and written on the main context.
//
// The in-memory scan store (XueniKit's MemoryScanStore) announces every
// mutation; this is what writes them through, and what seeds a fresh store
// at launch from what earlier sessions saved. Bodies and images are
// read cache-first by the reader and written the moment they arrive.

import Foundation
import SwiftData
import XueniKit

@MainActor
final class CacheStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        context.autosaveEnabled = true
    }

    private func save() {
        do { try context.save() } catch { print("cache: save failed: \(error)") }
    }

    // MARK: - Seeding

    struct Seed {
        var rows: [PostRow]
        var feedSegments: [Segment]
        var authorSegments: [String: [Segment]]
        var feedHead: UInt64?
        var authorHeads: [String: UInt64]
    }

    func seed(chainId: Int) -> Seed {
        var seed = Seed(rows: [], feedSegments: [], authorSegments: [:], feedHead: nil, authorHeads: [:])
        let posts = FetchDescriptor<CachedPost>(predicate: #Predicate { $0.chainId == chainId })
        seed.rows = ((try? context.fetch(posts)) ?? []).map { $0.row }
        let ranges = FetchDescriptor<ScanRange>(predicate: #Predicate { $0.chainId == chainId })
        for range in (try? context.fetch(ranges)) ?? [] {
            let segment = Segment(UInt64(max(0, range.from)), UInt64(max(0, range.to)))
            if range.kind == "feed" {
                seed.feedSegments.append(segment)
            } else {
                seed.authorSegments[range.author, default: []].append(segment)
            }
        }
        let heads = FetchDescriptor<ScanHead>(predicate: #Predicate { $0.chainId == chainId })
        for head in (try? context.fetch(heads)) ?? [] {
            if head.kind == "feed" { seed.feedHead = UInt64(max(0, head.head)) } else { seed.authorHeads[head.author] = UInt64(max(0, head.head)) }
        }
        return seed
    }

    // MARK: - Write-through

    func apply(_ event: ScanStoreEvent, chainId: Int, store: MemoryScanStore) {
        switch event {
        case .rows(let rows):
            for row in rows { context.insert(CachedPost(row: row)) }
            save()
        case .feedRange:
            replaceRanges(chainId: chainId, kind: "feed", author: "", with: store.feedCoverage())
        case .authorBlock(let author, _):
            replaceRanges(chainId: chainId, kind: "author", author: author, with: store.authorOwnCoverage(author))
        case .feedHead(let head):
            context.insert(ScanHead(chainId: chainId, kind: "feed", author: "", head: Int(head)))
            save()
        case .authorHead(let author, let head):
            context.insert(ScanHead(chainId: chainId, kind: "author", author: author, head: Int(head)))
            save()
        case .blockTime(let block, let ts):
            let b = Int(block)
            let descriptor = FetchDescriptor<CachedPost>(predicate: #Predicate { $0.chainId == chainId && $0.block == b })
            for post in (try? context.fetch(descriptor)) ?? [] where post.ts == nil { post.ts = ts }
            save()
        case .reset:
            break
        }
    }

    private func replaceRanges(chainId: Int, kind: String, author: String, with segments: [Segment]) {
        let descriptor = FetchDescriptor<ScanRange>(predicate: #Predicate { $0.chainId == chainId && $0.kind == kind && $0.author == author })
        for old in (try? context.fetch(descriptor)) ?? [] { context.delete(old) }
        for seg in segments { context.insert(ScanRange(chainId: chainId, kind: kind, author: author, from: Int(seg.from), to: Int(seg.to))) }
        save()
    }

    // MARK: - Bodies and images

    func body(chainId: Int, txHash: String) -> CachedBody? {
        let key = CachedBody.key(chainId: chainId, txHash: txHash)
        var descriptor = FetchDescriptor<CachedBody>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func saveBody(chainId: Int, txHash: String, post: DecodedPost, sender: String?) -> CachedBody {
        let body = CachedBody(
            chainId: chainId,
            txHash: txHash,
            text: post.text,
            compressedBytes: post.compressedBytes,
            form: post.call.form.rawValue,
            hook: post.call.hook,
            hookDataHex: Hex.string(post.call.hookData),
            relayedAuthor: post.call.relayed?.author,
            relayedDeadline: post.call.relayed?.deadline,
            relayedSignatureHex: post.call.relayed.map { Hex.string($0.signature) },
            sender: sender
        )
        context.insert(body)
        save()
        return body
    }

    /// A body from an archive: the document alone, decoded by nobody.
    func saveArchivedBody(_ post: ArchivePost) {
        let body = CachedBody(
            chainId: post.chainId,
            txHash: post.txHash,
            text: post.text,
            compressedBytes: post.compressedBytes,
            form: post.hook == nil ? CallForm.publish.rawValue : CallForm.publishWithHook.rawValue,
            hook: post.hook,
            hookDataHex: "0x",
            relayedAuthor: nil,
            relayedDeadline: nil,
            relayedSignatureHex: nil,
            sender: nil
        )
        context.insert(body)
        save()
    }

    func image(chainId: Int, txHash: String) -> Data? {
        let key = CachedBody.key(chainId: chainId, txHash: txHash)
        var descriptor = FetchDescriptor<CachedImage>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.bytes
    }

    func saveImage(chainId: Int, txHash: String, bytes: Data) {
        context.insert(CachedImage(chainId: chainId, txHash: txHash, bytes: bytes))
        save()
    }

    // MARK: - Questions the pages ask

    func allBodies() -> [CachedBody] {
        (try? context.fetch(FetchDescriptor<CachedBody>(sortBy: [SortDescriptor(\.readAt, order: .reverse)]))) ?? []
    }

    func posts(chainId: Int, txHashes: [String]) -> [String: CachedPost] {
        var out: [String: CachedPost] = [:]
        let descriptor = FetchDescriptor<CachedPost>(predicate: #Predicate { $0.chainId == chainId && $0.eventIndex == 0 })
        for post in (try? context.fetch(descriptor)) ?? [] where txHashes.contains(post.txHash) { out[post.txHash] = post }
        return out
    }

    func post(chainId: Int, txHash: String, eventIndex: Int = 0) -> CachedPost? {
        let key = CachedPost.key(chainId: chainId, txHash: txHash, eventIndex: eventIndex)
        var descriptor = FetchDescriptor<CachedPost>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    struct Counts {
        var posts: Int
        var bodies: Int
        var images: Int
        var blocks: UInt64
    }

    func counts() -> Counts {
        let posts = (try? context.fetchCount(FetchDescriptor<CachedPost>())) ?? 0
        let bodies = (try? context.fetchCount(FetchDescriptor<CachedBody>())) ?? 0
        let images = (try? context.fetchCount(FetchDescriptor<CachedImage>())) ?? 0
        let ranges = (try? context.fetch(FetchDescriptor<ScanRange>())) ?? []
        let blocks = ranges.filter { $0.kind == "feed" }.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.to - $1.from + 1)) }
        return Counts(posts: posts, bodies: bodies, images: images, blocks: blocks)
    }

    /// Forget everything read from the chains. The reader's own store is untouched.
    func clear() {
        do {
            try context.delete(model: CachedPost.self)
            try context.delete(model: CachedBody.self)
            try context.delete(model: CachedImage.self)
            try context.delete(model: ScanRange.self)
            try context.delete(model: ScanHead.self)
            save()
        } catch {
            print("cache: clear failed: \(error)")
        }
    }
}

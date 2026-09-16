// ReaderHub.swift — the readers, one per chain, and what the pages see.
//
// The pages observe this one object. Every scan store, feed and walk in
// the Kit announces its changes through a listener; the hub folds them
// into a single counter, `tick`, that a page reads when it takes a
// snapshot — so a sweep's findings reach the screen window by window, and
// nothing is fetched twice because two pages wanted it at once.

import Foundation
import Observation
import SwiftData
import XueniKit

@MainActor
@Observable
final class ReaderHub {
    let prefs: Preferences
    let cache: CacheStore
    let readers: [ChainReader]
    let ens: ENSResolver?

    /// Bumped (at most once per turn of the run loop) whenever anything read changed.
    private(set) var tick = 0
    /// Verified ENS names, by lowercase address.
    private(set) var names: [String: String] = [:]
    /// The first line of bodies this phone holds, for list rows.
    private(set) var excerpts: [String: String] = [:]

    @ObservationIgnored private var bumpScheduled = false
    @ObservationIgnored private var feeds: [String: MergedFeed] = [:]
    @ObservationIgnored private var authorLists: [String: MergedWalks] = [:]
    @ObservationIgnored private var followFeeds: [String: MergedWalks] = [:]
    @ObservationIgnored private var nameLookups = Set<String>()
    @ObservationIgnored private var excerptLookups = Set<String>()

    init(prefs: Preferences, cache: CacheStore) {
        self.prefs = prefs
        self.cache = cache
        readers = Chains.all.map { ChainReader(chain: $0, cache: cache, prefs: prefs) }
        ens = readers.first { $0.chain.hasENS }.map { ENSResolver(io: $0.io) }
        for reader in readers {
            reader.feed.listeners.add { [weak self] in self?.bump() }
            reader.store.listeners.add { [weak self] in self?.bump() }
        }
        prefs.onEndpointsChanged = { [weak self] in
            self?.readers.forEach { $0.applyEndpoints() }
        }
    }

    var strings: Strings { Strings(prefs.lang) }

    private func bump() {
        if bumpScheduled { return }
        bumpScheduled = true
        Task { @MainActor in
            self.bumpScheduled = false
            self.tick &+= 1
        }
    }

    func reader(_ chainId: Int) -> ChainReader? {
        readers.first { $0.chain.id == chainId }
    }

    // MARK: - Feeds and lists

    /// The home feed over every chain, or over one.
    func feed(chainFilter: Int?) -> MergedFeed {
        let selected = chainFilter.map { id in readers.filter { $0.chain.id == id } } ?? readers
        let key = selected.map { String($0.chain.id) }.joined(separator: ",")
        if let feed = feeds[key] { return feed }
        let feed = MergedFeed(chains: selected.map { (source: $0.source, feed: $0.feed, floor: $0.chain.deployBlock) }, pageSize: ChainReader.pageSize)
        feed.listeners.add { [weak self] in self?.bump() }
        feeds[key] = feed
        return feed
    }

    /// One author's posts across every chain, merged by time.
    func authorList(_ author: String) -> MergedWalks {
        let key = author.lowercased()
        if let list = authorLists[key] { return list }
        let list = MergedWalks(walks: readers.map { WalkSource(source: $0.source, author: key, list: $0.authorList(key)) }, pageSize: nil)
        list.listeners.add { [weak self] in self?.bump() }
        authorLists[key] = list
        return list
    }

    /// The followed authors' posts, merged by time and paged.
    func followFeed(_ addresses: [String]) -> MergedWalks {
        let clean = Array(Set(addresses.map { $0.lowercased() })).sorted()
        let key = clean.joined(separator: ",")
        if let feed = followFeeds[key] { return feed }
        var walks: [WalkSource] = []
        for reader in readers {
            for author in clean { walks.append(WalkSource(source: reader.source, author: author, list: reader.authorList(author))) }
        }
        let feed = MergedWalks(walks: walks, pageSize: ChainReader.pageSize)
        feed.listeners.add { [weak self] in self?.bump() }
        followFeeds[key] = feed
        return feed
    }

    /// Reading `tick` inside a view's body ties the view to every change;
    /// the snapshots below do so, so a page that takes one re-renders as
    /// the scans behind it move.
    func feedSnapshot(chainFilter: Int?) -> MergedFeed.Snapshot {
        _ = tick
        return feed(chainFilter: chainFilter).snapshot
    }

    func authorSnapshot(_ author: String) -> MergedWalks.Snapshot {
        _ = tick
        return authorList(author).snapshot
    }

    func followSnapshot(_ addresses: [String]) -> MergedWalks.Snapshot {
        _ = tick
        return followFeed(addresses).snapshot
    }

    func feedState(_ chainId: Int) -> FeedController.Snapshot? {
        _ = tick
        return reader(chainId)?.feed.snapshot
    }

    func observe() {
        _ = tick
    }

    // MARK: - Posts

    /// A post by transaction hash when the link didn't say which chain:
    /// one receipt read per chain, the lowest chain id that has it wins.
    func findPostAnywhere(txHash: String, eventIndex: Int) async -> PostRow? {
        for reader in readers {
            if let row = try? await reader.findMeta(txHash: txHash, eventIndex: eventIndex) { return row }
        }
        return nil
    }

    /// `{ total, byChain }` — total is nil until every chain has answered.
    func counts(author: String) async -> (total: UInt64?, byChain: [Int: UInt64?]) {
        var byChain: [Int: UInt64?] = [:]
        var total: UInt64 = 0
        var complete = true
        for reader in readers {
            if let n = try? await reader.count(author: author) {
                byChain[reader.chain.id] = n
                total += n
            } else {
                byChain[reader.chain.id] = .some(nil)
                complete = false
            }
        }
        return (complete ? total : nil, byChain)
    }

    // MARK: - Names

    /// The verified ENS name for an address, once it is known; asking
    /// starts the lookup, and the answer arrives through `names`.
    func ensName(for address: String) -> String? {
        let key = address.lowercased()
        if let name = names[key] { return name }
        guard let ens = ens, !nameLookups.contains(key), Hex.isAddress(key) else { return nil }
        nameLookups.insert(key)
        Task { @MainActor in
            if let name = await ens.name(for: key) { self.names[key] = name }
        }
        return nil
    }

    /// The address a typed name points at, or nil.
    func resolve(name: String) async -> String? {
        guard let ens = ens else { return nil }
        return await ens.address(for: name)
    }

    /// The name and the short address, or the short address alone.
    func label(for address: String) -> String {
        ensName(for: address) ?? Format.shortAddress(address)
    }

    // MARK: - Excerpts

    /// The first line of a post's body when this phone holds it.
    func excerpt(for row: PostRow) -> String? {
        let key = "\(row.chainId):\(row.txHash)"
        if let hit = excerpts[key] { return hit }
        guard !excerptLookups.contains(key) else { return nil }
        excerptLookups.insert(key)
        Task { @MainActor in
            if let body = self.cache.body(chainId: row.chainId, txHash: row.txHash) {
                self.excerpts[key] = Markdown.excerpt(Document.parse(body.text).markdown, maxChars: 160)
            }
        }
        return nil
    }

    func noteExcerpt(chainId: Int, txHash: String, markdown: String) {
        excerpts["\(chainId):\(txHash.lowercased())"] = Markdown.excerpt(markdown, maxChars: 160)
    }

    // MARK: - The cache

    func clearCache() {
        cache.clear()
        for reader in readers { reader.forgetEverything() }
        feeds.removeAll()
        authorLists.removeAll()
        followFeeds.removeAll()
        excerpts.removeAll()
        excerptLookups.removeAll()
        bump()
    }
}

// MARK: - Times, in the reader's language

enum Times {
    static func relative(_ ts: Int?, lang: Lang, exact: Bool, now: Date = Date()) -> String? {
        guard let ts = ts else { return nil }
        let strings = Strings(lang)
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let seconds = abs(now.timeIntervalSince(date))
        if seconds < 60 { return strings["time.justNow"] }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = lang.locale
        formatter.unitsStyle = .full
        let text = formatter.localizedString(for: date, relativeTo: now)
        return exact ? text : strings.t("time.about", ["time": text])
    }

    static func absolute(_ ts: Int?, lang: Lang) -> String? {
        guard let ts = ts else { return nil }
        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    static func absolute(_ date: Date, lang: Lang) -> String {
        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

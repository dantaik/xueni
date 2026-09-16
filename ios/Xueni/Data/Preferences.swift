// Preferences.swift — the reader's few settings, in UserDefaults.
//
// The endpoint lists per chain, the rescan delay, the interface language,
// and where the following page was read up to. Small, plain, and carried
// in the settings file with the followed authors (SettingsFile.swift in
// the Kit); the three keys the web app has and this app has no use for —
// the publish target, the theme, the console log switch — are kept and
// written back so a file that travels through the phone loses nothing.

import Foundation
import Observation
import XueniKit

@MainActor
@Observable
final class Preferences {
    private struct Stored: Codable {
        var lang: String?
        var rescanDelayMinutes: Double?
        var rpcs: [String: [String]]?
        var seenTs: Int?
        var publishChain: Int?
        var theme: String?
        var log: Bool?
    }

    private static let key = "xueni.prefs.v1"
    private let defaults: UserDefaults

    var lang: Lang { didSet { persist() } }
    var rescanDelayMinutes: Double { didSet { persist() } }
    /// Custom endpoint lists; a chain without one uses the registry defaults.
    var customRPCs: [Int: [String]] {
        didSet {
            persist()
            onEndpointsChanged?()
        }
    }
    /// The time (seconds) of the newest post seen on the following page.
    var seenTs: Int { didSet { persist() } }
    var publishChain: Int? { didSet { persist() } }
    var theme: String? { didSet { persist() } }
    var log: Bool? { didSet { persist() } }

    @ObservationIgnored var onEndpointsChanged: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        // English by default, as on the web — unless the phone itself reads Chinese.
        let phoneReadsChinese = Locale.preferredLanguages.first.map { $0.lowercased().hasPrefix("zh") } ?? false
        lang = stored.lang.flatMap(Lang.init(rawValue:)) ?? (phoneReadsChinese ? .zh : .en)
        rescanDelayMinutes = stored.rescanDelayMinutes.map { max(0, $0) } ?? 1
        var rpcs: [Int: [String]] = [:]
        for (key, list) in stored.rpcs ?? [:] {
            if let id = Int(key), Chains.isKnown(id) { rpcs[id] = list.filter(SettingsFile.isHTTPURL) }
        }
        customRPCs = rpcs
        seenTs = stored.seenTs ?? 0
        publishChain = stored.publishChain
        theme = stored.theme
        log = stored.log
    }

    private func persist() {
        var rpcs: [String: [String]] = [:]
        for (id, list) in customRPCs where !list.isEmpty { rpcs[String(id)] = list }
        let stored = Stored(lang: lang.rawValue, rescanDelayMinutes: rescanDelayMinutes, rpcs: rpcs, seenTs: seenTs, publishChain: publishChain, theme: theme, log: log)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    var strings: Strings { Strings(lang) }

    var rescanDelay: TimeInterval { rescanDelayMinutes * 60 }

    /// The ordered endpoints for a chain: the reader's list, else the defaults.
    func rpcURLs(for chain: Chain) -> [String] {
        if let custom = customRPCs[chain.id], !custom.isEmpty { return custom }
        return chain.defaultRPCs
    }

    func hasCustomRPCs(_ chain: Chain) -> Bool {
        !(customRPCs[chain.id] ?? []).isEmpty
    }

    /// Replace one chain's list. The defaults, or nothing, means "not customized".
    func setRPCs(_ urls: [String], for chain: Chain) {
        let clean = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(SettingsFile.isHTTPURL)
        if clean.isEmpty || clean == chain.defaultRPCs {
            customRPCs[chain.id] = nil
        } else {
            customRPCs[chain.id] = clean
        }
    }

    /// Remember how far the following page got. Never moves backwards.
    func markSeen(_ ts: Int) {
        if ts > seenTs { seenTs = ts }
    }

    // MARK: - The settings file

    func snapshot(following: [String]) -> SettingsSnapshot {
        var rpcs: [Int: [String]] = [:]
        for chain in Chains.all { rpcs[chain.id] = rpcURLs(for: chain) }
        return SettingsSnapshot(rpcs: rpcs, rescanDelayMinutes: rescanDelayMinutes, lang: lang, following: following, publishChain: publishChain, theme: theme, log: log)
    }

    /// Apply what a file said; the followed authors are the caller's (they live in the reader store).
    func apply(_ patch: SettingsPatch) {
        if let rpcs = patch.rpcs {
            for (id, list) in rpcs {
                if let chain = Chains.chain(id: id) { setRPCs(list, for: chain) }
            }
        }
        if let minutes = patch.rescanDelayMinutes { rescanDelayMinutes = minutes }
        if let lang = patch.lang { self.lang = lang }
        if let chain = patch.publishChain { publishChain = chain }
        if let theme = patch.theme { self.theme = theme }
        if let log = patch.log { self.log = log }
    }
}

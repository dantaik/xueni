// SettingsFile.swift — the reader's preferences as one file, out and back in.
//
// The same `xueni.settings` document the web app writes: the endpoint
// lists per chain, the rescan delay, the interface language, the followed
// authors. A file from the web app restores the phone and the other way
// round; keys the phone has no use for (the publish chain, the theme, the
// console log switch) are carried through unchanged so nothing is lost on
// the way back.

import Foundation

public enum Lang: String, Codable, Sendable, CaseIterable {
    case en
    case zh

    public var name: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        }
    }

    public var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en")
        case .zh: return Locale(identifier: "zh-Hans")
        }
    }
}

/// Every preference, as it stands.
public struct SettingsSnapshot: Sendable, Equatable {
    /// chainId -> endpoints, in preference order (the defaults when unset).
    public var rpcs: [Int: [String]]
    public var rescanDelayMinutes: Double
    public var lang: Lang
    public var following: [String]
    /// Carried through for the web app: the publish target, the theme, the log switch.
    public var publishChain: Int?
    public var theme: String?
    public var log: Bool?

    public init(rpcs: [Int: [String]], rescanDelayMinutes: Double, lang: Lang, following: [String], publishChain: Int? = nil, theme: String? = nil, log: Bool? = nil) {
        self.rpcs = rpcs
        self.rescanDelayMinutes = rescanDelayMinutes
        self.lang = lang
        self.following = following
        self.publishChain = publishChain
        self.theme = theme
        self.log = log
    }
}

/// What a settings file said, one field at a time, each only when valid.
public struct SettingsPatch: Sendable, Equatable {
    public var rpcs: [Int: [String]]?
    public var rescanDelayMinutes: Double?
    public var lang: Lang?
    public var following: [String]?
    public var publishChain: Int??
    public var theme: String??
    public var log: Bool?

    public init() {}
}

public enum SettingsProblem: Sendable, Equatable {
    case notJSON
    case notObject
    case notXueni
    case badFormat(Int)
    case rpcsShape
    case unknownChain(String)
    case chainListShape(Int)
    case droppedEndpoints(chainId: Int, count: Int)
    case rescanShape
    case langShape
    case followingShape
    case followingDropped(Int)
    case nothing
}

public enum SettingsSummary: Sendable, Equatable {
    case customEndpoints(chainId: Int, count: Int)
    case defaultEndpoints(chainId: Int)
    case rescanDelay(Double)
    case lang(Lang)
    case following(Int)
    case publishChain(Int?)
    case theme(String?)
    case log(Bool)
}

public struct SettingsReading: Sendable {
    public var patch: SettingsPatch
    public var problems: [SettingsProblem]
    public var summary: [SettingsSummary]
}

public enum SettingsFile {
    public static let format = 1

    public static func isHTTPURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (t.hasPrefix("http://") || t.hasPrefix("https://")) && !t.contains(" ") && t.count > 8
    }

    public static func fileName(now: Date = Date()) -> String {
        "xueni-settings-\(String(Archive.isoFormatter.string(from: now).prefix(10))).json"
    }

    /// The document as text, the way the file holds it.
    public static func serialize(_ s: SettingsSnapshot, now: Date = Date()) throws -> Data {
        var rpcs: [String: JSON] = [:]
        for (id, list) in s.rpcs { rpcs[String(id)] = .array(list.map(JSON.string)) }
        var doc: [String: JSON] = [
            "xueni": .object(["settings": .number(Double(format))]),
            "exportedAt": .string(Archive.isoFormatter.string(from: now)),
            "rpcs": .object(rpcs),
            "rescanDelayMinutes": .number(s.rescanDelayMinutes),
            "lang": .string(s.lang.rawValue),
            "following": .array(s.following.map(JSON.string)),
            "publishChain": s.publishChain.map { .number(Double($0)) } ?? .null,
            "theme": s.theme.map(JSON.string) ?? .null,
        ]
        if let log = s.log { doc["log"] = .bool(log) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSON.object(doc))
    }

    /// Read a settings file: what can be applied, what was wrong with the
    /// rest, and what applying would do. Unknown keys are ignored.
    public static func parse(_ data: Data) -> SettingsReading {
        var patch = SettingsPatch()
        var problems: [SettingsProblem] = []
        var summary: [SettingsSummary] = []
        let raw: JSON
        do {
            raw = try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            return SettingsReading(patch: patch, problems: [.notJSON], summary: [])
        }
        guard let doc = raw.object else { return SettingsReading(patch: patch, problems: [.notObject], summary: []) }
        guard let marker = doc["xueni"]?["settings"] else { return SettingsReading(patch: patch, problems: [.notXueni], summary: []) }
        guard case .number(let version) = marker, Int(version) == format else {
            if case .number(let v) = marker { return SettingsReading(patch: patch, problems: [.badFormat(Int(v))], summary: []) }
            return SettingsReading(patch: patch, problems: [.notXueni], summary: [])
        }

        if let rpcsValue = doc["rpcs"], !rpcsValue.isNull {
            if let map = rpcsValue.object {
                var rpcs: [Int: [String]] = [:]
                for (key, list) in map.sorted(by: { $0.key < $1.key }) {
                    guard let id = Int(key), let chain = Chains.chain(id: id) else {
                        problems.append(.unknownChain(key))
                        continue
                    }
                    guard let entries = list.array else {
                        problems.append(.chainListShape(id))
                        continue
                    }
                    let good = entries.compactMap { $0.string }.filter(isHTTPURL).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if good.count < entries.count { problems.append(.droppedEndpoints(chainId: id, count: entries.count - good.count)) }
                    rpcs[id] = good
                    if !good.isEmpty && good != chain.defaultRPCs {
                        summary.append(.customEndpoints(chainId: id, count: good.count))
                    } else {
                        summary.append(.defaultEndpoints(chainId: id))
                    }
                }
                if !rpcs.isEmpty { patch.rpcs = rpcs }
            } else {
                problems.append(.rpcsShape)
            }
        }
        if let value = doc["rescanDelayMinutes"], !value.isNull {
            if case .number(let n) = value, n.isFinite, n >= 0 {
                patch.rescanDelayMinutes = n
                summary.append(.rescanDelay(n))
            } else {
                problems.append(.rescanShape)
            }
        }
        if let value = doc["publishChain"] {
            if value.isNull {
                patch.publishChain = .some(nil)
                summary.append(.publishChain(nil))
            } else if case .number(let n) = value, Chains.isKnown(Int(n)) {
                patch.publishChain = .some(Int(n))
                summary.append(.publishChain(Int(n)))
            }
        }
        if let value = doc["lang"], !value.isNull {
            if let s = value.string, let lang = Lang(rawValue: s) {
                patch.lang = lang
                summary.append(.lang(lang))
            } else {
                problems.append(.langShape)
            }
        }
        if let value = doc["theme"] {
            if value.isNull {
                patch.theme = .some(nil)
                summary.append(.theme(nil))
            } else if let s = value.string, s == "light" || s == "dark" {
                patch.theme = .some(s)
                summary.append(.theme(s))
            }
        }
        if let value = doc["following"], !value.isNull {
            if let list = value.array {
                let good = list.compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(Hex.isAddress).map { $0.lowercased() }
                if good.count < list.count { problems.append(.followingDropped(list.count - good.count)) }
                var seen = Set<String>()
                patch.following = good.filter { seen.insert($0).inserted }
                summary.append(.following(patch.following!.count))
            } else {
                problems.append(.followingShape)
            }
        }
        if let value = doc["log"], case .bool(let b) = value {
            patch.log = b
            summary.append(.log(b))
        }
        if summary.isEmpty && problems.isEmpty { problems.append(.nothing) }
        return SettingsReading(patch: patch, problems: problems, summary: summary)
    }
}

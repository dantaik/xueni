// PostRef.swift — cross-article references (xueni-spec §8.1, SPEC §3.4).
//
//     [<chainSlug>:]0x<64 hex>[/<eventIndex>]
//
// The transaction that published a post, an optional 0-based ordinal for
// the Post event within it (default 0), and an optional chain prefix. With
// no prefix the reference means the chain the referring post is on. A full
// or partial URL of the web app is accepted too, so a pasted link works.

import Foundation

public struct PostRef: Sendable, Hashable {
    public let chainId: Int
    /// Lowercase.
    public let txHash: String
    public let eventIndex: Int

    public init(chainId: Int, txHash: String, eventIndex: Int = 0) {
        self.chainId = chainId
        self.txHash = txHash.lowercased()
        self.eventIndex = eventIndex
    }

    /// Read a reference; nil when it is not one, or names a chain we don't
    /// know, or names none and there is no chain to assume.
    public static func parse(_ value: String, defaultChainId: Int? = nil) -> PostRef? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let ref = parseReference(text, defaultChainId: defaultChainId) { return ref }
        return parseURL(text, defaultChainId: defaultChainId)
    }

    private static func parseReference(_ text: String, defaultChainId: Int?) -> PostRef? {
        var slug: String? = nil
        var rest = Substring(text)
        if let colon = rest.firstIndex(of: ":"), !rest[rest.startIndex..<colon].hasPrefix("0x") {
            let head = String(rest[rest.startIndex..<colon])
            guard isSlug(head) else { return nil }
            slug = head
            rest = rest[rest.index(after: colon)...]
        }
        var index = 0
        if let slash = rest.firstIndex(of: "/") {
            let digits = rest[rest.index(after: slash)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits) else { return nil }
            index = n
            rest = rest[rest.startIndex..<slash]
        }
        let hash = String(rest)
        guard Hex.isHash(hash) else { return nil }
        let chainId: Int?
        if let slug = slug {
            chainId = Chains.chain(slug: slug)?.id
        } else {
            chainId = defaultChainId
        }
        guard let id = chainId else { return nil }
        return PostRef(chainId: id, txHash: hash, eventIndex: index)
    }

    /// `/<chain>/tx/0x…/<n>` anywhere in a URL of the web app.
    private static func parseURL(_ text: String, defaultChainId: Int?) -> PostRef? {
        guard let range = text.range(of: "/tx/0x") else { return nil }
        let before = text[text.startIndex..<range.lowerBound]
        let after = text[text.index(range.lowerBound, offsetBy: 4)...]
        var hash = String(after.prefix(66))
        guard Hex.isHash(hash) else { return nil }
        hash = hash.lowercased()
        var rest = after.dropFirst(66)
        var index = 0
        if rest.hasPrefix("/") {
            rest = rest.dropFirst()
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty { index = Int(digits) ?? 0 }
            rest = rest.dropFirst(digits.count)
        }
        if let next = rest.first, !["/", "?", "#"].contains(next) { return nil }
        let segment = before.split(separator: "/").last.map(String.init) ?? ""
        let chainId: Int?
        if let chain = Chains.chain(slug: segment), isSlug(segment) {
            chainId = chain.id
        } else {
            chainId = defaultChainId
        }
        guard let id = chainId else { return nil }
        return PostRef(chainId: id, txHash: hash, eventIndex: index)
    }

    private static func isSlug(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    /// The shortest honest form: no chain prefix when it is the same chain
    /// as the post carrying it, and no `/0`.
    public func formatted(currentChainId: Int? = nil) -> String {
        let prefix = (currentChainId != nil && currentChainId == chainId) ? "" : "\(Chains.chain(id: chainId)?.slug ?? String(chainId)):"
        let suffix = eventIndex == 0 ? "" : "/\(eventIndex)"
        return "\(prefix)\(txHash)\(suffix)"
    }

    /// The canonical web link for this post — what a reader pastes.
    public func webURL(base: String = "https://xueni.xyz") -> URL {
        let slug = Chains.chain(id: chainId)?.slug ?? String(chainId)
        return URL(string: "\(base)/\(slug)/tx/\(txHash)/\(eventIndex)")!
    }
}

public enum PostRefs {
    /// Every `[text](0x<64 hex>[/n])` reference inside a Markdown body.
    public static func references(in markdown: String) -> [(text: String, ref: (txHash: String, eventIndex: Int))] {
        var out: [(String, (String, Int))] = []
        let chars = Array(markdown)
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" else { i += 1; continue }
            guard let close = chars[i...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(" else { i += 1; continue }
            guard let end = chars[(close + 2)...].firstIndex(of: ")") else { i += 1; continue }
            let text = String(chars[(i + 1)..<close])
            let target = String(chars[(close + 2)..<end])
            if !text.contains("]"), let parsed = parseTarget(target) {
                out.append((text, parsed))
            }
            i = end + 1
        }
        return out
    }

    /// `0x<64 hex>[/n]`, the target of an in-article reference.
    static func parseTarget(_ target: String) -> (String, Int)? {
        var hash = target
        var index = 0
        if let slash = target.firstIndex(of: "/") {
            hash = String(target[target.startIndex..<slash])
            let digits = target[target.index(after: slash)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits) else { return nil }
            index = n
        }
        guard Hex.isHash(hash) else { return nil }
        return (hash.lowercased(), index)
    }

    /// Every `![alt](eth:0x…)` image an article refers to, as lowercase
    /// transaction hashes, in order of first appearance.
    public static func imageRefs(in markdown: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for image in MarkdownScan.imageTargets(in: markdown) {
            guard image.hasPrefix("eth:") else { continue }
            let hash = String(image.dropFirst(4)).lowercased()
            guard Hex.isHash(hash), !seen.contains(hash) else { continue }
            seen.insert(hash)
            out.append(hash)
        }
        return out
    }
}

/// A tiny scanner shared with the Markdown parser: the targets of image
/// syntax, found the same way the renderer will find them.
enum MarkdownScan {
    static func imageTargets(in markdown: String) -> [String] {
        var out: [String] = []
        let chars = Array(markdown)
        var i = 0
        while i + 1 < chars.count {
            guard chars[i] == "!", chars[i + 1] == "[" else { i += 1; continue }
            guard let close = chars[(i + 2)...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(" else { i += 2; continue }
            guard let end = chars[(close + 2)...].firstIndex(of: ")") else { i += 2; continue }
            var target = String(chars[(close + 2)..<end])
            if let space = target.firstIndex(where: { $0 == " " || $0 == "\t" }) { target = String(target[target.startIndex..<space]) }
            out.append(target)
            i = end + 1
        }
        return out
    }
}

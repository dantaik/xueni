// Document.swift — the payload as TEXT: front-matter and Markdown (SPEC §4).
//
// The decompressed payload is a human-readable Markdown document with an
// optional YAML-ish front-matter block. This is the text layer alone —
// building that document and taking it apart — a port of
// webapp/src/lib/payloadText.js, whose reading rules are frozen: a document
// on chain must read the same everywhere, for ever.

import Foundation

/// A document taken apart: every front-matter key as written (unknown ones
/// included, in the order they first appeared), the tags parsed out of the
/// `tags` key, and the body.
public struct ParsedDocument: Sendable, Equatable {
    public var meta: [String: String]
    public var metaOrder: [String]
    public var tags: [String]
    public var markdown: String

    public init(meta: [String: String] = [:], metaOrder: [String] = [], tags: [String] = [], markdown: String = "") {
        self.meta = meta
        self.metaOrder = metaOrder
        self.tags = tags
        self.markdown = markdown
    }

    /// The front-matter without the tags: what `meta` means to a reader.
    public var otherMeta: [(key: String, value: String)] {
        metaOrder.compactMap { key in
            guard key != "tags", let value = meta[key] else { return nil }
            return (key, value)
        }
    }
}

public enum Document {
    /// The keys this app writes, in the order it writes them (SPEC §4.1).
    public static let frontMatterKeys = ["tags", "lang", "re", "supersedes", "prev", "series", "part"]

    /// `title` is the bytes32 argument, never a front-matter key.
    public static let reservedKeys: Set<String> = ["title"]

    // MARK: - Reading

    /// Split optional front-matter from a Markdown document (SPEC §4.2).
    /// Conservative: the first line must be exactly `---`, a closing `---`
    /// must exist, and every line between must be blank or `key: value`.
    public static func parse(_ text: String) -> ParsedDocument {
        let lines = lines(of: text)
        guard let first = lines.first, trim(first[...]) == "---" else {
            return ParsedDocument(markdown: text)
        }
        var end = -1
        for i in 1..<lines.count where trim(lines[i][...]) == "---" {
            end = i
            break
        }
        guard end != -1 else { return ParsedDocument(markdown: text) }

        var meta: [String: String] = [:]
        var order: [String] = []
        if end > 1 {
            for i in 1..<end {
                let line = lines[i]
                if trim(line[...]).isEmpty { continue }
                guard let colon = line.firstIndex(of: ":") else {
                    return ParsedDocument(markdown: text) // not key: value → not front-matter
                }
                let key = trim(line[line.startIndex..<colon])
                let value = trim(line[line.index(after: colon)...])
                if meta[key] == nil { order.append(key) }
                meta[key] = value
            }
        }
        var body = lines[(end + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() } // the one separator blank line
        return ParsedDocument(meta: meta, metaOrder: order, tags: parseTags(meta["tags"]), markdown: body)
    }

    /// `"a, b"` (or `"[a, b]"`) → `["a", "b"]`; empty for anything blank.
    public static func parseTags(_ raw: String?) -> [String] {
        guard var s = raw, !s.isEmpty else { return [] }
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",", omittingEmptySubsequences: false)
            .map { trim($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Writing

    /// Build the document a payload holds (SPEC §4.1). Known keys are
    /// written in `frontMatterKeys` order and anything else after them,
    /// sorted by the ASCII value of the key, so the same draft always
    /// produces the same bytes. Empty values are left out; with nothing
    /// left the result is the bare body — unless the body would itself read
    /// as front-matter, which gets the empty block in front of it.
    public static func build(markdown: String, tags: [String] = [], meta: [String: String] = [:]) -> String {
        var entries: [(String, String)] = []
        let cleanTags = tags.map { trim($0[...]) }.filter { !$0.isEmpty }
        var merged = meta
        if !cleanTags.isEmpty { merged["tags"] = cleanTags.joined(separator: ", ") }
        for key in frontMatterKeys {
            if let value = merged[key].map({ trim($0[...]) }), !value.isEmpty { entries.append((key, value)) }
        }
        let known = Set(frontMatterKeys)
        let extra = merged.keys.filter { !known.contains($0) }.sorted { asciiLess($0, $1) }
        for key in extra {
            let value = trim(merged[key]![...])
            if !value.isEmpty { entries.append((key, value)) }
        }
        if entries.isEmpty {
            let parsedAlone = parse(markdown)
            return parsedAlone.markdown == markdown && parsedAlone.meta.isEmpty && parsedAlone.metaOrder.isEmpty
                ? markdown
                : "---\n---\n\n" + markdown
        }
        let block = entries.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return "---\n\(block)\n---\n\n\(markdown)"
    }

    // MARK: - What a writer refuses (SPEC §3, §10.3)

    /// A C0 control, DEL or C1 control anywhere in `s` other than those allowed.
    public static func hasControlCharacters(_ s: String, allowing allowed: Set<Character>) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let isControl = v < 0x20 || v == 0x7f || (0x80...0x9f).contains(v)
            if isControl && !allowed.contains(Character(scalar)) { return true }
        }
        return false
    }

    /// The key grammar a writer holds itself to: `[A-Za-z][A-Za-z0-9_-]*`.
    public static func isValidKey(_ key: String) -> Bool {
        let utf8 = Array(key.utf8)
        guard let first = utf8.first, isAlpha(first) else { return false }
        for c in utf8.dropFirst() where !(isAlpha(c) || isDigit(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")) {
            return false
        }
        return true
    }

    private static func isAlpha(_ c: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
    }

    // MARK: - Helpers

    /// The lines of a text, split on LF (U+000A) alone — as ECMAScript's
    /// `split("\n")` does. Swift treats "\r\n" as one Character, so a
    /// Character-wise split would keep CRLF documents in one line.
    public static func lines(of text: String) -> [String] {
        text.utf8.split(separator: 0x0a, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// ECMAScript `String.prototype.trim`: Unicode White_Space, U+FEFF and
    /// line terminators off both ends.
    static func trim(_ s: Substring) -> String {
        var scalars = s.unicodeScalars[...]
        while let f = scalars.first, isTrimmable(f) { scalars = scalars.dropFirst() }
        while let l = scalars.last, isTrimmable(l) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isTrimmable(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
            return true
        case 0x2000...0x200a:
            return true
        default:
            return false
        }
    }

    private static func asciiLess(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        for i in 0..<min(x.count, y.count) where x[i] != y[i] { return x[i] < y[i] }
        return x.count < y.count
    }
}

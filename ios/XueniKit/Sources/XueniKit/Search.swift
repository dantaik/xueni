// Search.swift — finding a word in what this device has read.
//
// Substring matching, not tokens. A tokeniser would have to know where
// words begin, and Chinese does not put spaces between them: the posts this
// app was written for would be the ones it could not search. A plain
// case-folded substring finds 香樟木箱 and "camphorwood chest" alike.

import Foundation

public struct SearchHit: Sendable, Equatable {
    public enum Where: String, Sendable { case title, tags, body }
    public var location: Where
    public var snippet: String
}

public enum Search {
    /// Case-folded for comparison, in whatever script the query is written in.
    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Characters of context to show on either side of a match.
    public static let snippetWidth = 160

    /// A run of text around `index`, cut at a space where there is one
    /// nearby so a snippet does not start mid-word.
    public static func snippet(_ text: String, around index: Int, width: Int = snippetWidth) -> String {
        let chars = Array(text)
        if chars.count <= width { return text }
        let half = width / 2
        var from = max(0, index - half)
        var to = min(chars.count, from + width)
        from = max(0, to - width)
        // Prefer a space near the cut — but only near it: a Chinese
        // paragraph has no spaces at all.
        if from > 0, let space = chars[from...].firstIndex(of: " "), space - from < 24 { from = space + 1 }
        if to < chars.count, let space = chars[from..<to].lastIndex(of: " "), to - space < 24, space > from { to = space }
        let head = from > 0 ? "…" : ""
        let tail = to < chars.count ? "…" : ""
        return head + String(chars[from..<to]).trimmingCharacters(in: .whitespacesAndNewlines) + tail
    }

    /// Does this post match `query` (already normalized), and where? The
    /// title and the tags are searched as well as the body.
    public static func match(title: String, tags: [String], markdown: String, query: String) -> SearchHit? {
        guard !query.isEmpty else { return nil }
        if title.lowercased().contains(query) { return SearchHit(location: .title, snippet: title) }
        if let tag = tags.first(where: { $0.lowercased().contains(query) }) { return SearchHit(location: .tags, snippet: tag) }
        let folded = markdown.lowercased()
        guard let range = folded.range(of: query) else { return nil }
        let at = folded.distance(from: folded.startIndex, to: range.lowerBound)
        return SearchHit(location: .body, snippet: snippet(markdown, around: at))
    }

    /// Split `text` around every occurrence of `query`, so a view can mark
    /// the matches: `[(text, hit)]`.
    public static func highlight(_ text: String, query: String) -> [(text: String, hit: Bool)] {
        guard !query.isEmpty else { return [(text, false)] }
        let folded = text.lowercased()
        // Case folding can change lengths in some scripts; when it does, do not risk mis-cut ranges.
        guard folded.count == text.count else { return [(text, false)] }
        let chars = Array(text)
        let foldedChars = Array(folded)
        let q = Array(query)
        var parts: [(String, Bool)] = []
        var at = 0
        var i = 0
        while i + q.count <= chars.count {
            if Array(foldedChars[i..<(i + q.count)]) == q {
                if i > at { parts.append((String(chars[at..<i]), false)) }
                parts.append((String(chars[i..<(i + q.count)]), true))
                i += q.count
                at = i
            } else {
                i += 1
            }
        }
        if at < chars.count { parts.append((String(chars[at...]), false)) }
        return parts.isEmpty ? [(text, false)] : parts
    }
}

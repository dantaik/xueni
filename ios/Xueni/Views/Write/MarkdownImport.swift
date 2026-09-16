// MarkdownImport.swift — a `.md` file becoming a draft.
//
// The other half of the round trip: a post saved as the exact text the
// chain holds, edited anywhere, and brought back. `title` is accepted from
// a file's front-matter as a convenience — it is how every static-site
// generator writes one — but it is not a Xueni key: on chain the title is
// its own argument, so it fills the title field and nothing is written
// under that name. Keys this version knows are kept; anything else is
// reported rather than smuggled on chain.

import Foundation
import XueniKit

struct ImportedDraft {
    var title: String
    var tags: [String]
    var meta: [String: String]
    var markdown: String
    var dropped: [String]
}

enum MarkdownImport {
    static func read(_ text: String, fileName: String = "") -> ImportedDraft {
        let doc = Document.parse(text)
        var kept: [String: String] = [:]
        var dropped: [String] = []
        for (key, value) in doc.meta {
            if key == "tags" || key == "title" { continue }
            if Document.frontMatterKeys.contains(key) { kept[key] = value } else { dropped.append(key) }
        }
        return ImportedDraft(
            title: title(from: doc.markdown, meta: doc.meta, fileName: fileName),
            tags: doc.tags,
            meta: kept,
            markdown: doc.markdown,
            dropped: dropped.sorted()
        )
    }

    /// A title for this document: the front-matter's, else the first
    /// heading, else the file name. Always cut to fit the on-chain field.
    static func title(from markdown: String, meta: [String: String], fileName: String) -> String {
        if let given = meta["title"], !given.isEmpty { return Title.fit(given) }
        for line in Document.lines(of: markdown) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { continue }
            var heading = t.drop(while: { $0 == "#" })
            guard heading.first == " " || heading.isEmpty else { continue }
            while heading.hasSuffix("#") { heading = heading.dropLast() }
            let text = heading.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return Title.fit(text) }
        }
        var name = fileName
        for ext in [".md", ".markdown", ".txt"] where name.lowercased().hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        return Title.fit(name)
    }
}

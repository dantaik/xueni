// Markdown.swift — the Markdown subset (xueni-spec §8), parsed to a tree.
//
// What is stored is Markdown, but only a small subset: headings, bold,
// italic, links, images, lists, blockquotes, inline and fenced code, GFM
// tables, paragraphs. This parser turns a body into blocks and inlines and
// nothing else — no HTML anywhere, which is the reader's whole defence
// against a body that anyone can publish: there is no markup to inject
// into. Raw HTML in a body is dropped, as the web reader drops it. Line
// breaks inside a paragraph are kept as breaks, as the web reader keeps
// them. What a URL may do is the renderer's decision (`LinkTarget`).

import Foundation

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case lineBreak
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(text: [MarkdownInline], url: String)
    case image(alt: String, url: String)
}

public enum TableAlignment: Sendable, Equatable {
    case none, left, center, right
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockquote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    case codeBlock(language: String?, code: String)
    case table(header: [[MarkdownInline]], alignments: [TableAlignment], rows: [[[MarkdownInline]]])
    case thematicBreak
}

/// Where a link may take the reader. The parser hands every URL through as
/// text; the renderer asks this before making anything clickable.
public enum LinkTarget: Equatable, Sendable {
    /// `https:`, `http:` or `mailto:` — the browser.
    case external(URL)
    /// `0x<txhash>[/n]` — another post, on the same chain.
    case post(txHash: String, eventIndex: Int)
    /// Anything else: shown as text, never followed.
    case none

    public static func of(_ url: String) -> LinkTarget {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = PostRefs.parseTarget(trimmed) { return .post(txHash: ref.0, eventIndex: ref.1) }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:") else { return .none }
        guard let parsed = URL(string: trimmed) else { return .none }
        return .external(parsed)
    }
}

/// Where an image's bytes may come from.
public enum ImageSource: Equatable, Sendable {
    /// `eth:0x<txhash>` — a transaction whose calldata is the image.
    case chain(txHash: String)
    case remote(URL)
    case none

    public static func of(_ url: String) -> ImageSource {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("eth:") {
            let hash = String(trimmed.dropFirst(4))
            return Hex.isHash(hash) ? .chain(txHash: hash.lowercased()) : .none
        }
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), let parsed = URL(string: trimmed) else { return .none }
        return .remote(parsed)
    }
}

public enum Markdown {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = Document.lines(of: text).map { line -> String in
            var s = line
            if s.hasSuffix("\r") { s.removeLast() }
            return s.replacingOccurrences(of: "\t", with: "    ")
        }
        return BlockParser(lines: lines).parse()
    }

    /// The first ~`maxChars` characters of a body as one line of plain
    /// text, for list rows. Markup is stripped, not rendered.
    public static func excerpt(_ markdown: String, maxChars: Int = 80) -> String {
        var pieces: [String] = []
        for block in parse(markdown) {
            collectText(block, into: &pieces)
            if pieces.joined(separator: " ").count > maxChars * 2 { break }
        }
        let text = pieces.joined(separator: " ").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if text.count <= maxChars { return text }
        let cut = String(text.prefix(maxChars + 1))
        if let space = cut.lastIndex(of: " "), space > cut.startIndex {
            return String(cut[cut.startIndex..<space]) + "…"
        }
        return String(text.prefix(maxChars)) + "…"
    }

    private static func collectText(_ block: MarkdownBlock, into out: inout [String]) {
        switch block {
        case .heading(_, let inlines), .paragraph(let inlines):
            out.append(plainText(inlines))
        case .blockquote(let blocks):
            for b in blocks { collectText(b, into: &out) }
        case .list(_, _, let items):
            for item in items { for b in item { collectText(b, into: &out) } }
        case .codeBlock:
            break
        case .table(let header, _, let rows):
            out.append(header.map(plainText).joined(separator: " "))
            for row in rows { out.append(row.map(plainText).joined(separator: " ")) }
        case .thematicBreak:
            break
        }
    }

    /// The text of inlines, images left out.
    public static func plainText(_ inlines: [MarkdownInline]) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let s): out += s
            case .lineBreak: out += " "
            case .code(let s): out += s
            case .emphasis(let c), .strong(let c), .strikethrough(let c): out += plainText(c)
            case .link(let c, _): out += plainText(c)
            case .image: break
            }
        }
        return out
    }
}

// MARK: - Blocks

private struct BlockParser {
    let lines: [String]

    func parse() -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append(.paragraph(InlineParser.parse(paragraph.joined(separator: "\n"))))
                paragraph = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Setext headings close a paragraph rather than interrupting it.
            if !paragraph.isEmpty, let level = setextLevel(line) {
                let text = paragraph.joined(separator: "\n")
                paragraph = []
                out.append(.heading(level: level, content: InlineParser.parse(text)))
                i += 1
                continue
            }

            if let fence = fenceStart(line) {
                flushParagraph()
                var code: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if fenceEnd(lines[j], fence: fence) { closed = true; break }
                    code.append(dedent(lines[j], by: fence.indent))
                    j += 1
                }
                out.append(.codeBlock(language: fence.language, code: code.joined(separator: "\n")))
                i = closed ? j + 1 : j
                continue
            }

            if let heading = atxHeading(line) {
                flushParagraph()
                out.append(.heading(level: heading.level, content: InlineParser.parse(heading.text)))
                i += 1
                continue
            }

            if isThematicBreak(line) {
                flushParagraph()
                out.append(.thematicBreak)
                i += 1
                continue
            }

            if isBlockquoteStart(line) {
                flushParagraph()
                var inner: [String] = []
                var j = i
                while j < lines.count, isBlockquoteStart(lines[j]) {
                    inner.append(stripBlockquoteMarker(lines[j]))
                    j += 1
                    // Lazy continuation: a plain line right after quoted text.
                    while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty, !isBlockquoteStart(lines[j]), !startsBlock(lines[j]), !(inner.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                        inner.append(lines[j])
                        j += 1
                    }
                }
                out.append(.blockquote(BlockParser(lines: inner).parse()))
                i = j
                continue
            }

            if let marker = listMarker(line) {
                flushParagraph()
                let (list, next) = parseList(from: i, first: marker)
                out.append(list)
                i = next
                continue
            }

            if paragraph.isEmpty, i + 1 < lines.count, line.contains("|"), let alignments = tableDelimiter(lines[i + 1]) {
                let header = splitCells(line)
                if header.count == alignments.count {
                    var rows: [[[MarkdownInline]]] = []
                    var j = i + 2
                    while j < lines.count {
                        let candidate = lines[j]
                        if candidate.trimmingCharacters(in: .whitespaces).isEmpty || !candidate.contains("|") || startsBlock(candidate) { break }
                        var cells = splitCells(candidate).map(InlineParser.parse)
                        if cells.count < header.count { cells += Array(repeating: [], count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        j += 1
                    }
                    out.append(.table(header: header.map(InlineParser.parse), alignments: alignments, rows: rows))
                    i = j
                    continue
                }
            }

            if paragraph.isEmpty, indentation(line) >= 4 {
                var code: [String] = []
                var j = i
                while j < lines.count, indentation(lines[j]) >= 4 || lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    if lines[j].trimmingCharacters(in: .whitespaces).isEmpty, j + 1 < lines.count, indentation(lines[j + 1]) < 4, !lines[j + 1].trimmingCharacters(in: .whitespaces).isEmpty { break }
                    code.append(dedent(lines[j], by: 4))
                    j += 1
                }
                while let last = code.last, last.trimmingCharacters(in: .whitespaces).isEmpty { code.removeLast() }
                out.append(.codeBlock(language: nil, code: code.joined(separator: "\n")))
                i = j
                continue
            }

            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        flushParagraph()
        return out
    }

    // MARK: Lists

    private struct ListMarker {
        let ordered: Bool
        let number: Int
        let bullet: Character?
        let indent: Int
        /// Where the item's content begins on the marker line.
        let contentOffset: Int
    }

    private func listMarker(_ line: String) -> ListMarker? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i <= 3, i < chars.count else { return nil }
        let indent = i
        if "-*+".contains(chars[i]) {
            let after = i + 1
            if after == chars.count { return ListMarker(ordered: false, number: 0, bullet: chars[i], indent: indent, contentOffset: after + 1) }
            guard chars[after] == " " else { return nil }
            var content = after
            while content < chars.count, chars[content] == " " { content += 1 }
            if content - after > 4 { content = after + 1 }
            return ListMarker(ordered: false, number: 0, bullet: chars[i], indent: indent, contentOffset: content)
        }
        var j = i
        while j < chars.count, chars[j].isASCII, chars[j].isNumber, j - i < 9 { j += 1 }
        guard j > i, j < chars.count, chars[j] == "." || chars[j] == ")" else { return nil }
        let after = j + 1
        let number = Int(String(chars[i..<j])) ?? 1
        if after == chars.count { return ListMarker(ordered: true, number: number, bullet: nil, indent: indent, contentOffset: after + 1) }
        guard chars[after] == " " else { return nil }
        var content = after
        while content < chars.count, chars[content] == " " { content += 1 }
        if content - after > 4 { content = after + 1 }
        return ListMarker(ordered: true, number: number, bullet: nil, indent: indent, contentOffset: content)
    }

    private func parseList(from start: Int, first: ListMarker) -> (MarkdownBlock, Int) {
        var items: [[String]] = []
        var i = start
        while i < lines.count {
            guard let marker = listMarker(lines[i]), marker.ordered == first.ordered, marker.bullet == first.bullet, marker.indent < first.contentOffset else { break }
            let markerLine = Array(lines[i])
            var item: [String] = [markerLine.count > marker.contentOffset ? String(markerLine[marker.contentOffset...]) : ""]
            var j = i + 1
            while j < lines.count {
                let candidate = lines[j]
                let blank = candidate.trimmingCharacters(in: .whitespaces).isEmpty
                if blank {
                    // A blank line stays in the item only if indented content follows.
                    if j + 1 < lines.count, indentation(lines[j + 1]) >= marker.contentOffset {
                        item.append("")
                        j += 1
                        continue
                    }
                    break
                }
                if indentation(candidate) >= marker.contentOffset {
                    item.append(dedent(candidate, by: marker.contentOffset))
                    j += 1
                    continue
                }
                // Lazy continuation of a paragraph inside the item.
                if listMarker(candidate) == nil, !startsBlock(candidate), let last = item.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                    item.append(candidate.trimmingCharacters(in: .whitespaces))
                    j += 1
                    continue
                }
                break
            }
            items.append(item)
            i = j
            // Skip one blank line between items of the same list.
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count, let next = listMarker(lines[i + 1]), next.ordered == first.ordered, next.bullet == first.bullet {
                i += 1
            }
        }
        let parsed = items.map { BlockParser(lines: $0).parse() }
        return (.list(ordered: first.ordered, start: first.ordered ? first.number : 1, items: parsed), i)
    }

    // MARK: Line shapes

    private func indentation(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else { break }
        }
        return n
    }

    private func dedent(_ line: String, by n: Int) -> String {
        var s = Substring(line)
        var removed = 0
        while removed < n, let f = s.first, f == " " {
            s = s.dropFirst()
            removed += 1
        }
        return String(s)
    }

    private func setextLevel(_ line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private struct Fence {
        let char: Character
        let length: Int
        let indent: Int
        let language: String?
    }

    private func fenceStart(_ line: String) -> Fence? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = Array(line.dropFirst(indent))
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        var n = 0
        while n < rest.count, rest[n] == first { n += 1 }
        guard n >= 3 else { return nil }
        let info = String(rest[n...]).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(char: first, length: n, indent: indent, language: language?.isEmpty == false ? language : nil)
    }

    private func fenceEnd(_ line: String, fence: Fence) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard indentation(line) <= 3, !t.isEmpty, t.allSatisfy({ $0 == fence.char }) else { return false }
        return t.count >= fence.length
    }

    private func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard indentation(line) <= 3 else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for c in t {
            if c == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let after = t.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Closing hashes are decoration.
        while text.hasSuffix("#") { text.removeLast() }
        if text.hasSuffix("\\") { text.append("#") }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private func isThematicBreak(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let t = line.replacingOccurrences(of: " ", with: "")
        guard t.count >= 3, let first = t.first, "-*_".contains(first) else { return false }
        return t.allSatisfy { $0 == first }
    }

    private func isBlockquoteStart(_ line: String) -> Bool {
        indentation(line) <= 3 && line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private func stripBlockquoteMarker(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix(">") { s = s.dropFirst() }
        if s.hasPrefix(" ") { s = s.dropFirst() }
        return String(s)
    }

    private func startsBlock(_ line: String) -> Bool {
        fenceStart(line) != nil || atxHeading(line) != nil || isThematicBreak(line) || isBlockquoteStart(line) || listMarker(line) != nil
    }

    // MARK: Tables

    private func tableDelimiter(_ line: String) -> [TableAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let cells = splitCells(t)
        guard !cells.isEmpty else { return nil }
        var out: [TableAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.contains("-"), c.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (true, false): out.append(.left)
            case (false, true): out.append(.right)
            default: out.append(.none)
            }
        }
        return out
    }

    private func splitCells(_ line: String) -> [String] {
        var t = Substring(line.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t = t.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for c in t {
            if escaped {
                current.append(c == "|" ? "|" : "\\\(c)")
                escaped = false
                continue
            }
            if c == "\\" { escaped = true; continue }
            if c == "`" { inCode.toggle() }
            if c == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(c)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - Inlines

struct InlineParser {
    private let chars: [Character]

    private init(_ text: String) {
        chars = Array(text)
    }

    static func parse(_ text: String) -> [MarkdownInline] {
        InlineParser(text).parseRange(0, chars: nil)
    }

    private func parseRange(_ start: Int, chars slice: [Character]?) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var text = ""
        var i = start

        func flush() {
            if !text.isEmpty {
                out.append(contentsOf: autolinked(text))
                text = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count, isPunctuation(chars[i + 1]) {
                    text.append(chars[i + 1])
                    i += 2
                } else if i + 1 < chars.count, chars[i + 1] == "\n" {
                    flush()
                    out.append(.lineBreak)
                    i += 2
                } else {
                    text.append(c)
                    i += 1
                }
            case "\n":
                // Every newline inside a paragraph is a break, as on the web.
                while text.hasSuffix(" ") { text.removeLast() }
                flush()
                out.append(.lineBreak)
                i += 1
            case "`":
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                if let close = findRun("`", length: n, from: i + n) {
                    flush()
                    var code = String(chars[(i + n)..<close])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    out.append(.code(code.replacingOccurrences(of: "\n", with: " ")))
                    i = close + n
                } else {
                    text += String(repeating: "`", count: n)
                    i += n
                }
            case "!":
                if i + 1 < chars.count, chars[i + 1] == "[", let link = parseLink(at: i + 1) {
                    flush()
                    out.append(.image(alt: Markdown.plainText(InlineParser.parse(link.text)), url: link.url))
                    i = link.end
                } else {
                    text.append(c)
                    i += 1
                }
            case "[":
                if let link = parseLink(at: i) {
                    flush()
                    out.append(.link(text: InlineParser.parse(link.text), url: link.url))
                    i = link.end
                } else {
                    text.append(c)
                    i += 1
                }
            case "<":
                if let auto = parseAutolink(at: i) {
                    flush()
                    out.append(.link(text: [.text(auto.url)], url: auto.url))
                    i = auto.end
                } else if let end = htmlTagEnd(at: i) {
                    // Raw HTML is not in the subset: dropped, as the web reader
                    // drops it — and the space on each side of it folds into one.
                    i = end
                    if text.hasSuffix(" "), i < chars.count, chars[i] == " " { i += 1 }
                } else {
                    text.append(c)
                    i += 1
                }
            case "&":
                if let entity = parseEntity(at: i) {
                    text += entity.text
                    i = entity.end
                } else {
                    text.append(c)
                    i += 1
                }
            case "*", "_", "~":
                var n = 0
                while i + n < chars.count, chars[i + n] == c { n += 1 }
                if let span = delimitedSpan(c, count: n, at: i) {
                    flush()
                    let inner = InlineParser(String(chars[span.innerStart..<span.innerEnd])).parseRange(0, chars: nil)
                    switch span.kind {
                    case 1: out.append(.emphasis(inner))
                    case 2: out.append(.strong(inner))
                    case 3: out.append(.strong([.emphasis(inner)]))
                    default: out.append(.strikethrough(inner))
                    }
                    i = span.end
                } else {
                    text += String(repeating: c, count: n)
                    i += n
                }
            default:
                text.append(c)
                i += 1
            }
        }
        flush()
        return out
    }

    private func isPunctuation(_ c: Character) -> Bool {
        c.isASCII && (c.isPunctuation || c.isSymbol)
    }

    private func findRun(_ c: Character, length: Int, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == c {
                var n = 0
                while i + n < chars.count, chars[i + n] == c { n += 1 }
                if n == length { return i }
                i += n
            } else {
                i += 1
            }
        }
        return nil
    }

    // MARK: Links

    private struct Link {
        let text: String
        let url: String
        let end: Int
    }

    /// `[text](url "title")` at `at`; brackets in the text may nest one level.
    private func parseLink(at start: Int) -> Link? {
        guard chars[start] == "[" else { return nil }
        var depth = 0
        var i = start
        var close: Int? = nil
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" {
                // Skip a code span so a `]` inside it does not close the link.
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                if let end = findRun("`", length: n, from: i + n) { i = end + n; continue }
            }
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { close = i; break }
            }
            i += 1
        }
        guard let closeIndex = close, closeIndex + 1 < chars.count, chars[closeIndex + 1] == "(" else { return nil }
        var j = closeIndex + 2
        while j < chars.count, chars[j] == " " { j += 1 }
        var url = ""
        var parenDepth = 0
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" , chars[j] != "\n" {
                url.append(chars[j]); j += 1
            }
            guard j < chars.count, chars[j] == ">" else { return nil }
            j += 1
        } else {
            while j < chars.count {
                let c = chars[j]
                if c == "\\", j + 1 < chars.count { url.append(chars[j + 1]); j += 2; continue }
                if c == "(" { parenDepth += 1 }
                if c == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                }
                if c == " " || c == "\n" { break }
                url.append(c)
                j += 1
            }
        }
        // An optional title, then the closing paren.
        while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
        if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
            let quote = chars[j]
            j += 1
            while j < chars.count, chars[j] != quote { j += 1 }
            guard j < chars.count else { return nil }
            j += 1
            while j < chars.count, chars[j] == " " { j += 1 }
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return Link(text: String(chars[(start + 1)..<closeIndex]), url: url, end: j + 1)
    }

    private func parseAutolink(at start: Int) -> (url: String, end: Int)? {
        var i = start + 1
        var url = ""
        while i < chars.count, chars[i] != ">" {
            let c = chars[i]
            if c == " " || c == "\n" || c == "<" { return nil }
            url.append(c)
            i += 1
        }
        guard i < chars.count else { return nil }
        let lower = url.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:") else { return nil }
        return (url, i + 1)
    }

    private func htmlTagEnd(at start: Int) -> Int? {
        guard start + 1 < chars.count else { return nil }
        let next = chars[start + 1]
        guard next.isLetter || next == "/" || next == "!" || next == "?" else { return nil }
        var i = start + 1
        while i < chars.count, chars[i] != ">" {
            if chars[i] == "<" { return nil }
            i += 1
        }
        guard i < chars.count else { return nil }
        return i + 1
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "copy": "©",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
    ]

    private func parseEntity(at start: Int) -> (text: String, end: Int)? {
        var i = start + 1
        var name = ""
        while i < chars.count, chars[i] != ";", name.count < 10 {
            let c = chars[i]
            guard c.isASCII, c.isLetter || c.isNumber || c == "#" else { return nil }
            name.append(c)
            i += 1
        }
        guard i < chars.count, chars[i] == ";", !name.isEmpty else { return nil }
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            guard let v = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(v), v != 0 else { return nil }
            return (String(Character(scalar)), i + 1)
        }
        if name.hasPrefix("#") {
            guard let v = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(v), v != 0 else { return nil }
            return (String(Character(scalar)), i + 1)
        }
        guard let text = Self.namedEntities[name] else { return nil }
        return (text, i + 1)
    }

    // MARK: Emphasis

    private struct Span {
        let kind: Int // 1 em, 2 strong, 3 strong+em, 4 strike
        let innerStart: Int
        let innerEnd: Int
        let end: Int
    }

    private func delimitedSpan(_ c: Character, count: Int, at start: Int) -> Span? {
        let after = start + count
        guard after < chars.count, !chars[after].isWhitespace else { return nil }
        if c == "~" {
            guard count == 2, let close = findRun("~", length: 2, from: after), close > after, !chars[close - 1].isWhitespace else { return nil }
            return Span(kind: 4, innerStart: after, innerEnd: close, end: close + 2)
        }
        // Intraword underscores are literal: `snake_case_name`.
        if c == "_", start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber { return nil }
        let length = min(count, 3)
        // Prefer the closer matching the full run; fall back to shorter runs.
        for len in stride(from: length, through: 1, by: -1) {
            guard let close = findCloser(c, length: len, from: start + len) else { continue }
            let kind = len
            return Span(kind: kind, innerStart: start + len, innerEnd: close, end: close + len)
        }
        return nil
    }

    private func findCloser(_ c: Character, length: Int, from: Int) -> Int? {
        var i = from
        var codeDepth = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "`" { codeDepth.toggle(); i += 1; continue }
            if codeDepth { i += 1; continue }
            if ch == "\\" { i += 2; continue }
            if ch == c {
                var n = 0
                while i + n < chars.count, chars[i + n] == c { n += 1 }
                if n == length, i > from, !chars[i - 1].isWhitespace {
                    if c == "_", i + n < chars.count, chars[i + n].isLetter || chars[i + n].isNumber { i += n; continue }
                    return i
                }
                if n > length, i > from, !chars[i - 1].isWhitespace, c != "_" {
                    // `***x**` — take the last `length` of the run as the closer.
                    return i + n - length
                }
                i += n
                continue
            }
            i += 1
        }
        return nil
    }

    // MARK: Bare URLs

    /// GFM autolink literals: a bare `https://…` becomes a link.
    private func autolinked(_ text: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var rest = Substring(text)
        while let range = rest.range(of: "http") {
            let candidate = rest[range.lowerBound...]
            let lower = candidate.lowercased()
            let isURL = lower.hasPrefix("https://") || lower.hasPrefix("http://")
            let boundary = range.lowerBound == rest.startIndex || !(rest[rest.index(before: range.lowerBound)].isLetter || rest[rest.index(before: range.lowerBound)].isNumber)
            guard isURL, boundary else {
                let upTo = rest.index(range.lowerBound, offsetBy: 4)
                if !rest[rest.startIndex..<upTo].isEmpty { out.append(.text(String(rest[rest.startIndex..<upTo]))) }
                rest = rest[upTo...]
                continue
            }
            var end = candidate.firstIndex { $0.isWhitespace || $0 == "<" } ?? candidate.endIndex
            var url = candidate[candidate.startIndex..<end]
            while let last = url.last, ".,;:!?)\"'".contains(last) {
                if last == ")", url.filter({ $0 == "(" }).count >= url.filter({ $0 == ")" }).count { break }
                url = url.dropLast()
                end = candidate.index(before: end)
            }
            if range.lowerBound > rest.startIndex { out.append(.text(String(rest[rest.startIndex..<range.lowerBound]))) }
            out.append(.link(text: [.text(String(url))], url: String(url)))
            rest = candidate[end...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return mergeText(out)
    }

    private func mergeText(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let s) = inline, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + s)
            } else {
                out.append(inline)
            }
        }
        return out
    }
}


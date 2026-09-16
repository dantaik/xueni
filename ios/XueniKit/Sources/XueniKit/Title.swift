// Title.swift — the bytes32 title (codec/SPEC.md §3.1).
//
// The UTF-8 bytes of the title, right-padded with zeros to 32 bytes. An
// ASCII letter is one byte, a Chinese character three, most emoji four, so
// an editor limits by bytes and never by characters. Reading back, trailing
// zero bytes are stripped and the rest is decoded in replacement mode: a
// foreign writer that cut a title mid-character has still published a post,
// and the post must read.

import Foundation

public enum Title {
    public static let maxBytes = 32

    /// How many bytes the title costs on chain.
    public static func byteLength(_ title: String) -> Int {
        title.utf8.count
    }

    /// The 32-byte word, or nil when the title does not fit.
    public static func encode(_ title: String) -> [UInt8]? {
        let bytes = Array(title.utf8)
        guard bytes.count <= maxBytes else { return nil }
        return bytes + [UInt8](repeating: 0, count: maxBytes - bytes.count)
    }

    /// The title a word holds. Never fails: invalid UTF-8 becomes U+FFFD.
    public static func decode(_ word: [UInt8]) -> String {
        var end = word.count
        while end > 0 && word[end - 1] == 0 { end -= 1 }
        return String(decoding: word[0..<end], as: UTF8.self)
    }

    /// Cut `title` to what a bytes32 can hold, at a grapheme boundary.
    public static func fit(_ title: String) -> String {
        var out = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while byteLength(out) > maxBytes && !out.isEmpty { out.removeLast() }
        return out
    }

    /// A decoded title cleaned for display: trailing U+FFFD (a cut multibyte
    /// tail) removed; nil when nothing is left, so a list can say "Untitled".
    public static func forDisplay(_ title: String) -> String? {
        var scalars = Array(title.unicodeScalars)
        while let last = scalars.last, last == "\u{FFFD}" { scalars.removeLast() }
        let clean = String(String.UnicodeScalarView(scalars))
        return clean.isEmpty ? nil : clean
    }

    /// What is wrong with a title a writer is asked to store, if anything.
    public static func problems(_ title: String) -> [String] {
        var out: [String] = []
        if byteLength(title) > maxBytes { out.append("TITLE_TOO_LONG") }
        if title.unicodeScalars.contains(where: { $0.value == 0 }) { out.append("TITLE_NUL") }
        if Document.hasControlCharacters(title, allowing: ["\t"]) { out.append("CONTROL_CHAR") }
        return out
    }
}

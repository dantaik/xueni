// Files.swift — files in and out: the share sheet, and reading what was picked.

import SwiftUI
import UIKit

/// A file offered to the share sheet ("Save to Files" is where it usually goes).
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum Files {
    /// Write `data` under `name` in a scratch directory the share sheet can read.
    static func temporary(named name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xueni-out", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The bytes of a file the reader picked, inside its security scope.
    static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }

    /// A file name from a day and a title, safe on every file system.
    static func name(day: Date = Date(), title: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let slug = title
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let base = slug.isEmpty ? "untitled" : String(slug.prefix(48))
        return "\(formatter.string(from: day))-\(base).\(ext)"
    }
}

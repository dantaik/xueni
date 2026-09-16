// MarkdownView.swift — a letter, rendered.
//
// The parser in the Kit turns a body into blocks and inlines and no
// markup; this turns them into views. Text runs become one attributed
// string per paragraph so that a line wraps as prose should; images sit
// between the runs as views of their own, loaded from the chain cache
// first. Links become tappable only when the Kit says where they may lead.

import SwiftUI
import UIKit
import XueniKit

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let chainId: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, chainId: chainId)
            }
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let chainId: Int

    var body: some View {
        switch block {
        case .heading(let level, let content):
            Text(InlineRenderer.attributed(content, base: Typo.heading(level), chainId: chainId))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 10 : 4)
        case .paragraph(let inlines):
            ParagraphView(inlines: inlines, chainId: chainId)
        case .blockquote(let inner):
            HStack(alignment: .top, spacing: 14) {
                Rectangle().fill(Ink.edge).frame(width: 2)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, b in BlockView(block: b, chainId: chainId) }
                }
            }
            .foregroundStyle(Ink.soft)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ordered ? "\(start + i)." : "•")
                            .font(Typo.body)
                            .foregroundStyle(Ink.faint)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(item.enumerated()), id: \.offset) { _, b in BlockView(block: b, chainId: chainId) }
                        }
                    }
                }
            }
        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Typo.bodyCode)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(Ink.sunken)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .table(let header, _, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(InlineRenderer.attributed(cell, base: .subheadline.weight(.semibold), chainId: chainId))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(InlineRenderer.attributed(cell, base: .subheadline, chainId: chainId))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        case .thematicBreak:
            Text("※")
                .font(.body)
                .foregroundStyle(Ink.ghost)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }
}

/// A paragraph: runs of text, with each image as a view of its own.
private struct ParagraphView: View {
    let inlines: [MarkdownInline]
    let chainId: Int

    private enum Piece {
        case text([MarkdownInline])
        case image(alt: String, url: String)
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        var run: [MarkdownInline] = []
        func flush() {
            // A run that is only line breaks around an image is not prose.
            let trimmed = run.drop(while: { $0 == .lineBreak }).reversed().drop(while: { $0 == .lineBreak }).reversed()
            if !trimmed.isEmpty { out.append(.text(Array(trimmed))) }
            run = []
        }
        for inline in inlines {
            if case .image(let alt, let url) = inline {
                flush()
                out.append(.image(alt: alt, url: url))
            } else {
                run.append(inline)
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let run):
                    Text(InlineRenderer.attributed(run, base: Typo.body, chainId: chainId))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let alt, let url):
                    ChainImageView(source: ImageSource.of(url), alt: alt, chainId: chainId)
                }
            }
        }
    }
}

enum InlineRenderer {
    /// The scheme an in-app post link is written under, for the tap to find it.
    static let postScheme = "xueni"

    static func postURL(chainId: Int, txHash: String, eventIndex: Int) -> URL {
        URL(string: "\(postScheme)://post/\(chainId)/\(txHash)/\(eventIndex)")!
    }

    /// The route a tapped in-app link names, if it is one.
    static func route(for url: URL) -> Route? {
        guard url.scheme == postScheme, url.host == "post" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let chainId = Int(parts[0]), Hex.isHash(parts[1]) else { return nil }
        let index = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return .post(chainId: chainId, txHash: parts[1].lowercased(), eventIndex: index)
    }

    static func attributed(_ inlines: [MarkdownInline], base: Font, chainId: Int) -> AttributedString {
        var out = AttributedString()
        append(inlines, to: &out, font: base, bold: false, italic: false, chainId: chainId)
        return out
    }

    private static func styled(_ font: Font, bold: Bool, italic: Bool) -> Font {
        var f = font
        if bold { f = f.weight(.semibold) }
        if italic { f = f.italic() }
        return f
    }

    private static func append(_ inlines: [MarkdownInline], to out: inout AttributedString, font: Font, bold: Bool, italic: Bool, chainId: Int) {
        for inline in inlines {
            switch inline {
            case .text(let s):
                var a = AttributedString(s)
                a.font = styled(font, bold: bold, italic: italic)
                out += a
            case .lineBreak:
                out += AttributedString("\n")
            case .code(let s):
                var a = AttributedString(s)
                a.font = Typo.bodyCode
                a.backgroundColor = Ink.sunken
                out += a
            case .emphasis(let content):
                append(content, to: &out, font: font, bold: bold, italic: true, chainId: chainId)
            case .strong(let content):
                append(content, to: &out, font: font, bold: true, italic: italic, chainId: chainId)
            case .strikethrough(let content):
                var a = AttributedString()
                append(content, to: &a, font: font, bold: bold, italic: italic, chainId: chainId)
                a.strikethroughStyle = Text.LineStyle.single
                out += a
            case .link(let content, let url):
                var a = AttributedString()
                append(content, to: &a, font: font, bold: bold, italic: italic, chainId: chainId)
                switch LinkTarget.of(url) {
                case .external(let target):
                    a.link = target
                    a.underlineStyle = Text.LineStyle.single
                    a.foregroundColor = Ink.ink
                case .post(let txHash, let eventIndex):
                    a.link = postURL(chainId: chainId, txHash: txHash, eventIndex: eventIndex)
                    a.underlineStyle = Text.LineStyle.single
                    a.foregroundColor = Ink.ink
                case .none:
                    a.foregroundColor = Ink.soft
                }
                out += a
            case .image(let alt, _):
                var a = AttributedString(alt.isEmpty ? "" : "[\(alt)]")
                a.foregroundColor = Ink.faint
                out += a
            }
        }
    }
}

/// An image referred to from a body: from the chain cache, else the chain;
/// a remote one straight from its URL. Tapping opens it at full size.
struct ChainImageView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    let source: ImageSource
    let alt: String
    let chainId: Int

    @State private var image: UIImage?
    @State private var failed = false
    @State private var lightbox = false

    var body: some View {
        VStack(spacing: 6) {
            switch source {
            case .chain(let txHash):
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { lightbox = true }
                } else if failed {
                    placeholder(prefs.strings["post.imageFailed"])
                } else {
                    placeholder(nil)
                        .task(id: txHash) {
                            guard let reader = hub.reader(chainId) else { failed = true; return }
                            do {
                                let data = try await reader.loadImage(txHash)
                                if let decoded = UIImage(data: data) { image = decoded } else { failed = true }
                            } catch {
                                failed = true
                            }
                        }
                }
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if phase.error != nil {
                        placeholder(alt)
                    } else {
                        placeholder(nil)
                    }
                }
            case .none:
                placeholder(alt)
            }
            if !alt.isEmpty {
                Text(alt)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .fullScreenCover(isPresented: $lightbox) {
            if let image = image {
                LightboxView(image: image, caption: alt)
            }
        }
    }

    private func placeholder(_ text: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Ink.sunken)
            if let text = text {
                Text(text).font(Typo.micro).foregroundStyle(Ink.faint).padding()
            } else {
                ProgressView().tint(Ink.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
    }
}

/// A picture that cost gas by the byte, actually looked at.
struct LightboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Preferences.self) private var prefs
    let image: UIImage
    let caption: String
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in scale = max(1, min(5, lastScale * value)) }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = 1; lastScale = 1 }
                    }
                if !caption.isEmpty {
                    Text(caption).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding(.horizontal)
                }
                Spacer()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .accessibilityLabel(prefs.strings["common.close"])
            .padding()
        }
    }
}

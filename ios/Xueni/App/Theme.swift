// Theme.swift — black, white and the greys between.
//
// The interface has no colour. Every token here is one of the system's
// semantic greys, which are already black-on-white in the light appearance
// and white-on-black in the dark one, and which the accessibility settings
// (bold text, increased contrast) already know how to adjust. The one
// accent colour the web app allows itself is not allowed here: links,
// buttons and selection are the ink itself. What carries the hierarchy
// instead is weight, size, the serif face of the letters, and space.

import SwiftUI
import UIKit

enum Ink {
    /// The page.
    static let paper = Color(uiColor: .systemBackground)
    /// A surface set a little apart: a code block, a well, a card.
    static let sunken = Color(uiColor: .secondarySystemBackground)
    /// Primary text.
    static let ink = Color.primary
    /// Secondary text: bylines, dates, counts.
    static let soft = Color.secondary
    /// Labels and meta.
    static let faint = Color(uiColor: .tertiaryLabel)
    /// Decorative only.
    static let ghost = Color(uiColor: .quaternaryLabel)
    /// Hairlines.
    static let edge = Color(uiColor: .separator)
}

enum Typo {
    /// A post's title in a list.
    static let listTitle = Font.system(.title3, design: .serif, weight: .semibold)
    /// The title on the post page.
    static let pageTitle = Font.system(size: 28, weight: .semibold, design: .serif)
    /// The letter itself.
    static let body = Font.system(size: 18, design: .serif)
    static let bodyStrong = Font.system(size: 18, weight: .semibold, design: .serif)
    static let bodyItalic = Font.system(size: 18, design: .serif).italic()
    static let bodyCode = Font.system(size: 15, design: .monospaced)
    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: return Font.system(size: 24, weight: .semibold, design: .serif)
        case 2: return Font.system(size: 22, weight: .semibold, design: .serif)
        case 3: return Font.system(size: 20, weight: .semibold, design: .serif)
        default: return Font.system(size: 18, weight: .semibold, design: .serif)
        }
    }
    /// Bylines, dates and counts.
    static let meta = Font.footnote
    static let micro = Font.caption
    /// Addresses and hashes.
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    /// Section labels: small caps in spirit, tracked.
    static let label = Font.caption.weight(.medium)
}

/// A single hairline, the only rule the interface draws.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Ink.edge).frame(height: 1 / UIScreen.main.scale)
    }
}

/// A small, tracked, uppercase label above a section.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Typo.label)
            .tracking(1.2)
            .foregroundStyle(Ink.faint)
    }
}

/// The outlined button every action uses: ink on paper, a hairline around it.
struct OutlineButtonStyle: ButtonStyle {
    var full = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: full ? .infinity : nil)
            .foregroundStyle(configuration.isPressed ? Ink.paper : Ink.ink)
            .background(configuration.isPressed ? Ink.ink : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.ink, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The filled twin, for the one primary action on a screen.
struct FilledButtonStyle: ButtonStyle {
    var full = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: full ? .infinity : nil)
            .foregroundStyle(Ink.paper)
            .background(Ink.ink.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// The standard page gutter.
    func gutter() -> some View { padding(.horizontal, 20) }
}

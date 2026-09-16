// Pieces.swift — the small views every page is made of.

import SwiftUI
import UIKit
import XueniKit

// MARK: - People

/// The blockies square in grey: the same pattern every wallet draws for an
/// address, without the colour.
struct IdenticonView: View {
    let address: String
    var size: CGFloat = 16

    var body: some View {
        let icon = Identicon.make(for: address)
        Canvas { context, canvasSize in
            let cell = canvasSize.width / CGFloat(Identicon.size)
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(Color(white: icon.background)))
            for y in 0..<Identicon.size {
                for x in 0..<Identicon.size {
                    let value = icon.cell(x: x, y: y)
                    guard value != 0 else { continue }
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell + 0.5, height: cell + 0.5)
                    context.fill(Path(rect), with: .color(Color(white: value == 1 ? icon.color : icon.spot)))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5))
        .overlay(RoundedRectangle(cornerRadius: size / 5).stroke(Ink.edge, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Identicon + the name an address has claimed, or its `0x0000....0000` form.
struct AuthorLabel: View {
    @Environment(ReaderHub.self) private var hub
    let address: String
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            IdenticonView(address: address, size: size)
            Text(hub.label(for: address))
                .font(Typo.meta)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(Ink.soft)
    }
}

// MARK: - Chains

struct ChainMark: View {
    let chainId: Int

    var body: some View {
        Text(Chains.name(of: chainId))
            .font(Typo.micro)
            .foregroundStyle(Ink.faint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.edge, lineWidth: 1))
    }
}

// MARK: - Rows

/// One post in a list: the title in serif, a line of its body when this
/// phone holds it, and who, where and when underneath.
struct PostRowView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    let row: TimedRow
    var showAuthor = true

    var body: some View {
        let s = prefs.strings
        VStack(alignment: .leading, spacing: 6) {
            Text(Title.forDisplay(row.row.title) ?? s["common.untitled"])
                .font(Typo.listTitle)
                .foregroundStyle(Title.forDisplay(row.row.title) == nil ? Ink.faint : Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let excerpt = hub.excerpt(for: row.row), !excerpt.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(Ink.soft)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if showAuthor { AuthorLabel(address: row.row.author) }
                ChainMark(chainId: row.chainId)
                if let when = Times.relative(row.ts, lang: prefs.lang, exact: row.exact) {
                    Text(when).font(Typo.micro).foregroundStyle(Ink.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - The edges of a list

/// Where a merged list stops being complete.
struct FrontierNote: View {
    @Environment(Preferences.self) private var prefs
    let frontier: Frontier
    var isAuthorList = false
    var scanning = false
    var onContinue: (() -> Void)?

    var body: some View {
        let s = prefs.strings
        let names = s.joinChains(Array(Set(frontier.leaders.map { $0.chainId })).sorted())
        let failed = frontier.leaders.first { $0.state == .error }
        let text: String = {
            if let failed = failed {
                let reason = Format.errorKey(failed.error ?? "")
                return s.t("frontier.readFailed", ["names": names, "reason": s.t(reason.key, ["block": reason.block ?? ""])])
            }
            if frontier.leaders.contains(where: { $0.state == .scanning }) || scanning {
                return s.t(isAuthorList ? "frontier.authorScanning" : "frontier.feedScanning", ["names": names])
            }
            if isAuthorList { return s.t("frontier.authorIncomplete", ["names": names]) }
            // A chain whose first scan has not started yet has no bound at all
            // (the frontier's time is infinite): it is still to be read.
            guard frontier.ts.isFinite else { return s.t("frontier.feedScanning", ["names": names]) }
            let when = Times.relative(Int(frontier.ts), lang: prefs.lang, exact: frontier.leaders.allSatisfy { $0.exact }) ?? ""
            return s.t("frontier.feedIncomplete", ["names": names, "when": when])
        }()
        VStack(spacing: 8) {
            Hairline()
            Text(text)
                .font(Typo.micro)
                .foregroundStyle(Ink.faint)
                .multilineTextAlignment(.center)
            if let onContinue = onContinue, !scanning {
                Button(s[isAuthorList ? "frontier.continueReading" : "frontier.continueScanning"], action: onContinue)
                    .buttonStyle(OutlineButtonStyle())
            }
            Hairline()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

/// The foot of a list: load more, loading, or nothing more.
struct LoadMoreButton: View {
    @Environment(Preferences.self) private var prefs
    let done: Bool
    let loading: Bool
    let action: () -> Void

    var body: some View {
        let s = prefs.strings
        Group {
            if done {
                Text(s["loadMore.noMore"]).font(Typo.micro).foregroundStyle(Ink.faint)
            } else {
                Button(action: action) {
                    if loading {
                        ProgressView().tint(Ink.ink)
                    } else {
                        Text(s["loadMore.label"])
                    }
                }
                .buttonStyle(OutlineButtonStyle(full: true))
                .disabled(loading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// A thin line and a caption while a chain is being read.
struct ScanProgressLine: View {
    @Environment(Preferences.self) private var prefs
    let chainId: Int
    let job: JobKind?
    let progress: SweepProgress?
    let fraction: Double?
    let budget: UInt64

    var body: some View {
        let s = prefs.strings
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction ?? 0)
                .tint(Ink.ink)
            HStack(spacing: 4) {
                Text(Chains.name(of: chainId))
                Text("·")
                if let p = progress {
                    Text(s.t("scanProgress.blockRange", ["from": Format.grouped(p.from), "to": Format.grouped(p.to)]) + s.t("scanProgress.read", ["fetched": Format.grouped(p.fetched), "budget": Format.grouped(budget)]))
                } else {
                    Text(s[job == .more ? "feed.jobMore" : job == .gap ? "feed.jobGap" : "feed.jobRefresh"])
                }
            }
            .font(Typo.micro)
            .foregroundStyle(Ink.faint)
            .lineLimit(1)
        }
    }
}

/// Nothing here, said plainly.
struct EmptyStateView: View {
    let title: String
    var text: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(Font.system(.title3, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
            if let text = text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Ink.soft)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action).buttonStyle(OutlineButtonStyle()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .gutter()
    }
}

/// A failure the reader is shown, in their language, with a way to retry.
struct ErrorLine: View {
    @Environment(Preferences.self) private var prefs
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        let s = prefs.strings
        let key = Format.errorKey(message)
        HStack(alignment: .top, spacing: 12) {
            Text(s.t(key.key, ["block": key.block ?? ""]))
                .font(.subheadline)
                .foregroundStyle(Ink.soft)
            Spacer()
            if let retry = retry {
                Button(s["common.retry"], action: retry).buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(.vertical, 8)
    }
}

/// A row of small facts separated by middle dots.
struct MetaLine<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(Typo.micro)
            .foregroundStyle(Ink.faint)
            .lineLimit(1)
    }
}

/// Text copied to the clipboard, with a moment's acknowledgement.
@MainActor
@Observable
final class CopyFeedback {
    var shown = false

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        shown = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.shown = false
        }
    }
}

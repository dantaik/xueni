// ScanView.swift — the block coverage kept on this phone.

import SwiftUI
import XueniKit

struct ScanView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let s = prefs.strings
        List {
            Section {
                Text(s["scan.intro"]).font(Typo.micro).foregroundStyle(Ink.faint)
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s["scan.title"]).font(Font.system(.title2, design: .serif, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(s["scan.subtitle"]).font(Typo.micro).foregroundStyle(Ink.faint)
                }
                .textCase(nil)
            }
            ForEach(hub.readers, id: \.chainId) { reader in
                let state = hub.feedState(reader.chainId)
                let coverage = state?.coverage ?? []
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(s["scan.globalHeading"])
                        if coverage.isEmpty {
                            Text(s["scan.noRanges"]).font(.subheadline).foregroundStyle(Ink.soft)
                        } else {
                            ForEach(Array(coverage.reversed().prefix(6)), id: \.self) { seg in
                                Text(s.t("scan.range", ["from": Format.grouped(seg.from), "to": Format.grouped(seg.to)])).font(Typo.mono).foregroundStyle(Ink.soft)
                            }
                            Text(s.t("scan.summary", ["segments": String(coverage.count), "blocks": Format.grouped(Segments.blockCount(coverage)), "cached": String(reader.store.coveredPosts().count)])
                                 + (state?.head.map { " · " + s.t("scan.syncedTo", ["block": Format.grouped($0)]) } ?? ""))
                                .font(Typo.micro).foregroundStyle(Ink.faint)
                        }
                        if let p = state?.progress, state?.job != nil {
                            ScanProgressLine(chainId: reader.chainId, job: state?.job, progress: p, fraction: state?.fraction, budget: reader.chain.scanBlocks)
                        }
                        Text(s.t("scan.budget", ["blocks": Format.grouped(reader.chain.scanBlocks), "floor": Format.grouped(reader.chain.deployBlock)])).font(Typo.micro).foregroundStyle(Ink.faint)
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(s["scan.authorHeading"])
                        let entries = reader.store.authorScanEntries()
                        if entries.isEmpty {
                            Text(s["scan.noAuthors"]).font(.subheadline).foregroundStyle(Ink.soft)
                        }
                        ForEach(entries.prefix(40), id: \.address) { entry in
                            NavigationLink(value: Route.author(entry.address)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    AuthorLabel(address: entry.address)
                                    Text("\(entry.segments.count) · \(s.count(entry.count, "common.post", "common.posts"))" + (entry.head.map { " · " + s.t("scan.syncedTo", ["block": Format.grouped($0)]) } ?? ""))
                                        .font(Typo.micro).foregroundStyle(Ink.faint)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(reader.chain.name).font(Font.system(.headline, design: .serif, weight: .semibold)).foregroundStyle(Ink.ink).textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
    }
}

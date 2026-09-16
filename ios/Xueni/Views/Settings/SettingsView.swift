// SettingsView.swift — the few things that are the reader's to decide.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XueniKit

struct SettingsView: View {
    @Environment(ReaderHub.self) private var hub
    @Environment(Preferences.self) private var prefs
    @Environment(\.modelContext) private var context
    @Query(sort: \FollowedAuthor.addedAt) private var follows: [FollowedAuthor]

    @State private var showSettingsImporter = false
    @State private var showArchiveImporter = false
    @State private var settingsReview: SettingsReview?
    @State private var archiveReview: ArchiveReview?
    @State private var shareFile: ShareFile?
    @State private var status: String?
    @State private var confirmClear = false
    @State private var counts: CacheStore.Counts?
    @State private var busy = false

    struct SettingsReview: Identifiable {
        let id = UUID()
        let name: String
        let reading: SettingsReading
    }

    struct ArchiveReview: Identifiable {
        let id = UUID()
        let name: String
        let reading: ArchiveReading
    }

    var body: some View {
        @Bindable var prefs = prefs
        let s = prefs.strings
        Form {
            Section {
                Picker("", selection: $prefs.lang) {
                    ForEach(Lang.allCases, id: \.self) { lang in Text(lang.name).tag(lang) }
                }
                .pickerStyle(.segmented)
                Text(s["settings.languageNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
            } header: { SectionLabel(s["settings.languageHeading"]).textCase(nil) }

            Section {
                ForEach(Chains.all) { chain in
                    NavigationLink(value: Route.endpoints(chainId: chain.id)) {
                        HStack {
                            Text(chain.name)
                            Spacer()
                            Text(s[prefs.hasCustomRPCs(chain) ? "settings.customized" : "settings.defaults"]).font(Typo.micro).foregroundStyle(Ink.faint)
                        }
                    }
                }
                Text(s["settings.endpointsNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
            } header: { SectionLabel(s["settings.endpoints"]).textCase(nil) }

            Section {
                Picker(s["settings.rescanLabel"], selection: $prefs.rescanDelayMinutes) {
                    ForEach([0.0, 1.0, 5.0, 15.0, 60.0], id: \.self) { minutes in
                        Text(minutes == 0 ? s["settings.rescanEvery"] : s.t("settings.rescanMinutes", ["minutes": String(Int(minutes))])).tag(minutes)
                    }
                }
                Text(s["settings.rescanNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
            } header: { SectionLabel(s["settings.rescanHeading"]).textCase(nil) }

            Section {
                if follows.isEmpty {
                    Text(s["following.none"]).font(.subheadline).foregroundStyle(Ink.soft)
                } else {
                    ForEach(follows) { follow in
                        NavigationLink(value: Route.author(follow.address)) { AuthorLabel(address: follow.address, size: 20) }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(follows[i]) }
                        try? context.save()
                    }
                }
                Text(s["following.settingsNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
            } header: { SectionLabel(s["settings.followingHeading"]).textCase(nil) }

            Section {
                Text(s["settings.backupNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
                Button(s["settings.exportSettings"]) { exportSettings() }
                Button(s["settings.importSettings"]) { showSettingsImporter = true }
            } header: { SectionLabel(s["settings.backupHeading"]).textCase(nil) }

            Section {
                Text(s["settings.archiveNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
                if let counts = counts {
                    Text(s.t("settings.archiveCounts", ["posts": String(counts.bodies), "images": String(counts.images)])).font(Typo.meta).foregroundStyle(Ink.soft)
                }
                Button(s["settings.exportArchive"]) { exportArchive() }.disabled(busy || (counts?.bodies ?? 0) == 0)
                Button(s["settings.importArchive"]) { showArchiveImporter = true }
            } header: { SectionLabel(s["settings.archiveHeading"]).textCase(nil) }

            Section {
                Text(s["settings.storageNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
                if let counts = counts {
                    Text(s.t("settings.cacheCounts", ["posts": String(counts.posts), "bodies": String(counts.bodies), "images": String(counts.images), "blocks": Format.grouped(counts.blocks)])).font(Typo.meta).foregroundStyle(Ink.soft)
                }
                NavigationLink(value: Route.scan) { Text(s["settings.scanPage"]) }
                Button(s["settings.clearCache"]) { confirmClear = true }
            } header: { SectionLabel(s["settings.storageHeading"]).textCase(nil) }

            Section {
                Text(s["settings.about"]).font(.subheadline).foregroundStyle(Ink.soft)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s["settings.contract"]).font(Typo.micro).foregroundStyle(Ink.faint)
                    Text(Chains.xueniAddress).font(Typo.monoSmall).textSelection(.enabled)
                }
                Link("github.com/dantaik/xueni", destination: URL(string: "https://github.com/dantaik/xueni")!).font(Typo.meta)
            } header: { SectionLabel("Xueni · 雪泥").textCase(nil) }

            if let status = status {
                Section { Text(status).font(Typo.meta).foregroundStyle(Ink.soft) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(s["settings.title"]).font(Font.system(.headline, design: .serif, weight: .semibold))
            }
        }
        .task { counts = hub.cache.counts() }
        .fileImporter(isPresented: $showSettingsImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case .success(let url) = result, let data = Files.read(url) else { return }
            settingsReview = SettingsReview(name: url.lastPathComponent, reading: SettingsFile.parse(data))
        }
        .fileImporter(isPresented: $showArchiveImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case .success(let url) = result, let data = Files.read(url) else { return }
            archiveReview = ArchiveReview(name: url.lastPathComponent, reading: Archive.parse(data))
        }
        .sheet(item: $settingsReview) { review in
            ReviewSheet(
                title: review.name,
                summary: review.reading.summary.map { SettingsText.line($0, s) },
                problems: review.reading.problems.map { SettingsText.line($0, s) },
                canApply: !review.reading.summary.isEmpty
            ) {
                applySettings(review.reading.patch)
                status = s["settings.applied"]
            }
        }
        .sheet(item: $archiveReview) { review in
            ReviewSheet(
                title: review.name,
                summary: review.reading.summary.map { SettingsText.line($0, s) },
                problems: review.reading.problems.map { SettingsText.line($0, s) },
                canApply: review.reading.document != nil && !review.reading.document!.posts.isEmpty
            ) {
                if let doc = review.reading.document {
                    let result = ArchiveBuilder.apply(doc, hub: hub)
                    status = s.t("settings.archiveApplied", ["posts": String(result.posts), "images": String(result.images), "skipped": String(result.skipped)])
                    counts = hub.cache.counts()
                }
            }
        }
        .sheet(item: $shareFile) { file in ShareSheet(items: [file.url]) }
        .confirmationDialog(s["settings.clearCacheConfirm"], isPresented: $confirmClear, titleVisibility: .visible) {
            Button(s["settings.clearCache"]) {
                hub.clearCache()
                counts = hub.cache.counts()
            }
            Button(s["common.cancel"], role: .cancel) {}
        }
    }

    private func exportSettings() {
        let snapshot = prefs.snapshot(following: follows.map { $0.address })
        guard let data = try? SettingsFile.serialize(snapshot), let url = try? Files.temporary(named: SettingsFile.fileName(), data: data) else { return }
        shareFile = ShareFile(url: url)
    }

    private func applySettings(_ patch: SettingsPatch) {
        prefs.apply(patch)
        if let following = patch.following {
            for follow in follows { context.delete(follow) }
            for address in following { context.insert(FollowedAuthor(address: address)) }
            try? context.save()
        }
    }

    private func exportArchive() {
        busy = true
        let doc = ArchiveBuilder.everything(hub: hub)
        if let url = try? ArchiveBuilder.write(doc) { shareFile = ShareFile(url: url) }
        busy = false
    }
}

/// What a file would do, before it does it.
struct ReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Preferences.self) private var prefs
    let title: String
    let summary: [String]
    let problems: [String]
    let canApply: Bool
    let apply: () -> Void

    var body: some View {
        let s = prefs.strings
        NavigationStack {
            List {
                if !summary.isEmpty {
                    Section(s["settings.reviewWill"]) {
                        ForEach(summary, id: \.self) { Text($0).font(.subheadline) }
                    }
                }
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Ink.soft) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(s["common.cancel"]) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s["settings.apply"]) {
                        apply()
                        dismiss()
                    }
                    .disabled(!canApply)
                }
            }
        }
    }
}

/// The lines a review is made of, in the reader's language.
enum SettingsText {
    static func line(_ summary: SettingsSummary, _ s: Strings) -> String {
        switch summary {
        case .customEndpoints(let chainId, let count): return s.t("settingsFile.customEndpoints", ["chain": s.chain(chainId), "count": String(count)])
        case .defaultEndpoints(let chainId): return s.t("settingsFile.defaultEndpoints", ["chain": s.chain(chainId)])
        case .rescanDelay(let minutes): return s.t("settingsFile.rescanDelay", ["minutes": minutes == minutes.rounded() ? String(Int(minutes)) : String(minutes)])
        case .lang(let lang): return s.t("settingsFile.lang", ["lang": lang.name])
        case .following(let count): return s.t("settingsFile.following", ["count": String(count)])
        case .publishChain(let chain): return s.t("settingsFile.publishChain", ["chain": chain.map(s.chain) ?? "—"])
        case .theme(let theme): return s.t("settingsFile.theme", ["theme": theme ?? "—"])
        case .log(let on): return s.t("settingsFile.log", ["state": on ? "on" : "off"])
        }
    }

    static func line(_ problem: SettingsProblem, _ s: Strings) -> String {
        switch problem {
        case .notJSON: return s["settingsFile.notJson"]
        case .notObject: return s["settingsFile.notObject"]
        case .notXueni: return s["settingsFile.notXueni"]
        case .badFormat(let format): return s.t("settingsFile.badFormat", ["format": String(format)])
        case .rpcsShape: return s["settingsFile.rpcsShape"]
        case .unknownChain(let id): return s.t("settingsFile.unknownChain", ["id": id])
        case .chainListShape(let chainId): return s.t("settingsFile.chainListShape", ["chain": s.chain(chainId)])
        case .droppedEndpoints(let chainId, let count): return s.t("settingsFile.droppedEndpoints", ["chain": s.chain(chainId), "count": String(count)])
        case .rescanShape: return s["settingsFile.rescanShape"]
        case .langShape: return s["settingsFile.langShape"]
        case .followingShape: return s["settingsFile.followingShape"]
        case .followingDropped(let count): return s.t("settingsFile.followingDropped", ["count": String(count)])
        case .nothing: return s["settingsFile.nothing"]
        }
    }

    static func line(_ summary: ArchiveChainSummary, _ s: Strings) -> String {
        var line = s.t("archive.chainLine", ["chain": s.chain(summary.chainId), "posts": String(summary.posts), "images": String(summary.images)])
        if summary.completeAuthors > 0 { line += " · " + s.t("archive.completeAuthors", ["count": String(summary.completeAuthors)]) }
        return line
    }

    static func line(_ problem: ArchiveProblem, _ s: Strings) -> String {
        switch problem {
        case .notJSON: return s["archive.notJson"]
        case .notArchive: return s["archive.notArchive"]
        case .wrongVersion(let version): return s.t("archive.wrongVersion", ["version": String(version)])
        case .wrongContract(let contract): return s.t("archive.wrongContract", ["contract": contract])
        case .droppedPosts(let count): return s.t("archive.droppedPosts", ["count": String(count)])
        case .droppedImages(let count): return s.t("archive.droppedImages", ["count": String(count)])
        case .empty: return s["archive.empty"]
        }
    }
}

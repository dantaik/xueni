// WriteView.swift — a letter written on the phone, published from the desk.
//
// The app reads without a wallet and writes without one too: what is
// written here is saved on this phone a moment after every change, and
// leaves it as a Markdown file — the same document the web app's
// "Import .md…" reads and the command-line tool publishes — so the bytes
// on chain are the same whichever way it goes.

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XueniKit

struct WriteView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @Query private var drafts: [Draft]

    @State private var title = ""
    @State private var tags = ""
    @State private var markdown = ""
    @State private var lang = ""
    @State private var re = ""
    @State private var supersedes = ""
    @State private var prev = ""
    @State private var series = ""
    @State private var part = ""
    @State private var savedAt: Date?
    @State private var loaded = false
    @State private var preview = false
    @State private var showImporter = false
    @State private var exportFile: ShareFile?
    @State private var note: String?
    @State private var confirmDiscard = false
    @State private var pendingImport: ImportedDraft?
    @State private var saveTask: Task<Void, Never>?
    @State private var showHandoff = false

    private var fields: String {
        [title, tags, markdown, lang, re, supersedes, prev, series, part].joined(separator: "\u{1F}")
    }

    var body: some View {
        let s = prefs.strings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                handoff(s)
                if preview {
                    previewView(s)
                } else {
                    editor(s)
                }
                actions(s)
            }
            .gutter()
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(s["write.title"]).font(Font.system(.headline, design: .serif, weight: .semibold))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(s[preview ? "write.edit" : "write.preview"]) { preview.toggle() }
            }
        }
        .task { loadDraft() }
        .onChange(of: fields) { _, _ in scheduleSave() }
        .onChange(of: state.pendingReply?.txHash) { _, _ in takePendingReply() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text, .data]) { result in
            guard case .success(let url) = result, let data = Files.read(url) else { return }
            let imported = MarkdownImport.read(String(decoding: data, as: UTF8.self), fileName: url.lastPathComponent)
            if isEmptyDraft { apply(imported, s) } else { pendingImport = imported }
        }
        .confirmationDialog(s["write.replaceDraft"], isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button(s["write.replace"]) {
                if let imported = pendingImport { apply(imported, s) }
                pendingImport = nil
            }
            Button(s["common.cancel"], role: .cancel) { pendingImport = nil }
        }
        .confirmationDialog(s["write.discardConfirm"], isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(s["write.discard"]) { discard() }
            Button(s["common.cancel"], role: .cancel) {}
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
    }

    // MARK: - Pieces

    private func handoff(_ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { showHandoff.toggle() }
            } label: {
                HStack {
                    Text(s["write.handoffTitle"]).font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: showHandoff ? "chevron.up" : "chevron.down").font(.caption)
                }
                .foregroundStyle(Ink.soft)
            }
            if showHandoff {
                Text(s["write.handoffBody"]).font(.subheadline).foregroundStyle(Ink.soft)
            }
        }
        .padding(12)
        .background(Ink.sunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func editor(_ s: Strings) -> some View {
        let used = Title.byteLength(title)
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(s["write.titleField"])
            TextField(s["write.titlePlaceholder"], text: $title, axis: .vertical)
                .font(Font.system(.title2, design: .serif, weight: .semibold))
            HStack {
                Text(s.t("write.titleBytes", ["used": String(used), "max": String(Title.maxBytes)]))
                if used > Title.maxBytes { Text("· " + s["write.titleTooLong"]).fontWeight(.semibold) }
            }
            .font(Typo.micro)
            .foregroundStyle(used > Title.maxBytes ? Ink.ink : Ink.faint)
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(s["write.tagsField"])
            TextField(s["write.tagsPlaceholder"], text: $tags)
                .font(.body)
                .autocorrectionDisabled()
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(s["write.bodyField"])
            ZStack(alignment: .topLeading) {
                if markdown.isEmpty {
                    Text(s["write.bodyPlaceholder"]).font(Typo.body).foregroundStyle(Ink.ghost).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $markdown)
                    .font(Typo.body)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.edge, lineWidth: 1))
        }
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(s["write.relationsNote"]).font(Typo.micro).foregroundStyle(Ink.faint)
                relationField(s["write.re"], $re, placeholder: s["write.refPlaceholder"], s: s)
                relationField(s["write.supersedes"], $supersedes, placeholder: s["write.refPlaceholder"], s: s)
                relationField(s["write.prev"], $prev, placeholder: s["write.refPlaceholder"], s: s)
                labelledField(s["write.series"], $series)
                labelledField(s["write.part"], $part)
                labelledField(s["write.lang"], $lang)
            }
            .padding(.top, 8)
        } label: {
            SectionLabel(s["write.relations"])
        }
        VStack(alignment: .leading, spacing: 4) {
            let bytes = draftDocument.utf8.count
            Text(s.t("write.estimate", ["bytes": Format.bytes(Int(Double(bytes) * 0.45))])).font(Typo.meta).foregroundStyle(Ink.soft)
            Text(s.t("write.estimateNote", ["text": Format.bytes(bytes)])).font(Typo.micro).foregroundStyle(Ink.faint)
            if let savedAt = savedAt {
                Text(s.t("write.savedAt", ["when": Times.absolute(savedAt, lang: prefs.lang)])).font(Typo.micro).foregroundStyle(Ink.faint)
            }
            if let note = note {
                Text(note).font(Typo.micro).foregroundStyle(Ink.soft)
            }
        }
    }

    private func relationField(_ label: String, _ text: Binding<String>, placeholder: String, s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Typo.micro).foregroundStyle(Ink.faint)
            TextField(placeholder, text: text).font(Typo.mono).autocorrectionDisabled().textInputAutocapitalization(.never)
            let value = text.wrappedValue.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, PostRef.parse(value, defaultChainId: Chains.ethereum.id) == nil {
                Text(s["write.invalidRef"]).font(Typo.micro).foregroundStyle(Ink.soft)
            }
        }
    }

    private func labelledField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Typo.micro).foregroundStyle(Ink.faint)
            TextField("", text: text).font(.body)
        }
    }

    private func previewView(_ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.isEmpty ? s["common.untitled"] : title).font(Typo.pageTitle).foregroundStyle(title.isEmpty ? Ink.faint : Ink.ink)
            if !tagList.isEmpty {
                Text(tagList.joined(separator: " · ")).font(Typo.micro).foregroundStyle(Ink.faint)
            }
            Hairline()
            MarkdownView(blocks: Markdown.parse(markdown), chainId: Chains.ethereum.id)
        }
    }

    private func actions(_ s: Strings) -> some View {
        HStack(spacing: 10) {
            Button(s["write.export"]) { export() }.buttonStyle(FilledButtonStyle()).disabled(isEmptyDraft)
            Button(s["write.import"]) { showImporter = true }.buttonStyle(OutlineButtonStyle())
            Spacer()
            Button(s["write.discard"]) { confirmDiscard = true }.buttonStyle(OutlineButtonStyle()).disabled(isEmptyDraft)
        }
    }

    // MARK: - The draft

    private var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var meta: [String: String] {
        var out: [String: String] = [:]
        for (key, value) in [("lang", lang), ("re", re), ("supersedes", supersedes), ("prev", prev), ("series", series), ("part", part)] {
            let v = value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { out[key] = v }
        }
        return out
    }

    private var draftDocument: String {
        Document.build(markdown: markdown, tags: tagList, meta: meta)
    }

    private var isEmptyDraft: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty && markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tagList.isEmpty && meta.isEmpty
    }

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        if let draft = drafts.first {
            title = draft.title
            tags = draft.tags
            markdown = draft.markdown
            lang = draft.lang
            re = draft.re
            supersedes = draft.supersedes
            prev = draft.prev
            series = draft.series
            part = draft.part
            savedAt = draft.updatedAt
        }
        takePendingReply()
    }

    private func takePendingReply() {
        guard let reply = state.pendingReply else { return }
        state.pendingReply = nil
        re = PostRef(chainId: reply.chainId, txHash: reply.txHash, eventIndex: reply.eventIndex).formatted()
        if title.isEmpty, !reply.title.isEmpty { title = Title.fit("Re: " + reply.title) }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            persist()
        }
    }

    private func persist() {
        if isEmptyDraft {
            for draft in drafts { context.delete(draft) }
            savedAt = nil
        } else {
            let draft = drafts.first ?? {
                let fresh = Draft()
                context.insert(fresh)
                return fresh
            }()
            draft.title = title
            draft.tags = tags
            draft.markdown = markdown
            draft.lang = lang
            draft.re = re
            draft.supersedes = supersedes
            draft.prev = prev
            draft.series = series
            draft.part = part
            draft.updatedAt = Date()
            savedAt = draft.updatedAt
        }
        try? context.save()
    }

    private func apply(_ imported: ImportedDraft, _ s: Strings) {
        title = imported.title
        tags = imported.tags.joined(separator: ", ")
        markdown = imported.markdown
        lang = imported.meta["lang"] ?? ""
        re = imported.meta["re"] ?? ""
        supersedes = imported.meta["supersedes"] ?? ""
        prev = imported.meta["prev"] ?? ""
        series = imported.meta["series"] ?? ""
        part = imported.meta["part"] ?? ""
        note = imported.dropped.isEmpty ? nil : s.t("write.importDropped", ["keys": imported.dropped.joined(separator: ", ")])
        preview = false
    }

    private func discard() {
        title = ""; tags = ""; markdown = ""; lang = ""; re = ""; supersedes = ""; prev = ""; series = ""; part = ""
        note = nil
        persist()
    }

    private func export() {
        let name = Files.name(title: title.isEmpty ? "untitled" : title, ext: "md")
        // A title goes in as `title:` so the web app fills its field from it.
        var withTitle = meta
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { withTitle["title"] = title }
        let text = Document.build(markdown: markdown, tags: tagList, meta: withTitle)
        if let url = try? Files.temporary(named: name, data: Data(text.utf8)) { exportFile = ShareFile(url: url) }
    }
}

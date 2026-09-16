// EndpointsView.swift — one chain's RPC endpoints, in the order they are tried.

import SwiftUI
import XueniKit

struct EndpointsView: View {
    let chainId: Int
    @Environment(Preferences.self) private var prefs

    private struct Entry: Identifiable, Equatable {
        let id = UUID()
        var url: String
    }

    @State private var entries: [Entry] = []
    @State private var newURL = ""
    @State private var loaded = false

    var body: some View {
        let s = prefs.strings
        let chain = Chains.chain(id: chainId) ?? Chains.ethereum
        List {
            Section {
                ForEach($entries) { $entry in
                    HStack(spacing: 10) {
                        Text(String((entries.firstIndex { $0.id == entry.id } ?? 0) + 1))
                            .font(Typo.micro).foregroundStyle(Ink.faint).monospacedDigit().frame(width: 14)
                        TextField("", text: $entry.url)
                            .font(Typo.mono)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                }
                .onDelete { offsets in entries.remove(atOffsets: offsets) }
                .onMove { from, to in entries.move(fromOffsets: from, toOffset: to) }
                HStack(spacing: 10) {
                    TextField(s["settings.endpointPlaceholder"], text: $newURL)
                        .font(Typo.mono)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit { add() }
                    Button(s["common.add"]) { add() }.disabled(!SettingsFile.isHTTPURL(newURL))
                }
            } header: {
                Text(chain.name).textCase(nil)
            } footer: {
                Text(s["settings.endpointsNote"])
            }
            Section {
                Button(s["settings.restoreDefaults"]) { entries = chain.defaultRPCs.map { Entry(url: $0) } }
            }
        }
        .toolbar { EditButton() }
        .navigationTitle(s["settings.endpoints"])
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                entries = prefs.rpcURLs(for: chain).map { Entry(url: $0) }
                loaded = true
            }
        }
        .onChange(of: entries) { _, fresh in
            if loaded { prefs.setRPCs(fresh.map { $0.url }, for: chain) }
        }
    }

    private func add() {
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SettingsFile.isHTTPURL(url) else { return }
        entries.append(Entry(url: url))
        newURL = ""
    }
}

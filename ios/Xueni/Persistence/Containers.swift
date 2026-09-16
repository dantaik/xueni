// Containers.swift — two SQLite files under one container.
//
// SwiftData lets one container hold several stores, each configuration
// naming the model types it keeps. The chain cache and the reader's own
// data get one file each, so that clearing the cache is deleting rows in
// one store and never touches the other.

import Foundation
import SwiftData

enum Containers {
    static let cacheModels: [any PersistentModel.Type] = [CachedPost.self, CachedBody.self, CachedImage.self, ScanRange.self, ScanHead.self]
    static let readerModels: [any PersistentModel.Type] = [FollowedAuthor.self, Draft.self]

    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Xueni", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func make() throws -> ModelContainer {
        let dir = try directory()
        let cache = ModelConfiguration("ChainCache", schema: Schema(cacheModels), url: dir.appendingPathComponent("ChainCache.store"))
        let reader = ModelConfiguration("Reader", schema: Schema(readerModels), url: dir.appendingPathComponent("Reader.store"))
        return try ModelContainer(for: Schema(cacheModels + readerModels), configurations: [cache, reader])
    }

    /// For previews and a last resort when the disk refuses.
    static func inMemory() -> ModelContainer {
        let all = Schema(cacheModels + readerModels)
        let config = ModelConfiguration(schema: all, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: all, configurations: [config])
    }
}

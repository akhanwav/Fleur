// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoListing.swift
//  Rivulet
//
//  One folder level's paged contents. The grid and the viewer it opens share
//  an instance, so the viewer pages through exactly what the grid shows.
//

import Foundation

@MainActor
final class PhotoListing {
    /// The provider and the library as it knows it; nil until one is registered.
    typealias Source = @MainActor () -> (provider: any PhotoProvider, library: MediaLibrary)?

    enum Change {
        case reloaded
        case appended(folders: Range<Int>, media: Range<Int>)
        case failed
    }

    static let pageSize = 200

    private(set) var folders: [PhotoItem] = []
    private(set) var media: [PhotoItem] = []
    private(set) var isLoading = false
    private(set) var error: Error?
    var hasMore: Bool { nextPage != nil }
    var onChange: ((Change) -> Void)?

    private let source: Source
    private let folder: MediaItemRef?
    private var nextPage: Page? = Page(offset: 0, limit: pageSize)
    private var seen = Set<MediaItemRef>()
    /// Bumped by `loadFirst`, so a page from before the reload is dropped.
    private var generation = 0

    init(folder: MediaItemRef?, source: @escaping Source) {
        self.folder = folder
        self.source = source
    }

    @discardableResult
    func loadFirst() -> Task<Void, Never>? {
        generation += 1
        folders = []
        media = []
        seen = []
        isLoading = false
        nextPage = Page(offset: 0, limit: Self.pageSize)
        // Start the page first, so the reset is announced as loading rather than empty.
        let task = loadMore()
        onChange?(.reloaded)
        return task
    }

    /// Appends the next page. A failed page keeps what is loaded and can be asked for again.
    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard !isLoading, let page = nextPage else { return nil }
        isLoading = true
        error = nil
        let generation = generation
        return Task {
            do {
                guard let (provider, library) = source() else { throw MediaProviderError.unreachable }
                let result = try await provider.photoPage(in: library, folder: folder, page: page)
                guard generation == self.generation else { return }
                let firstFolder = folders.count, firstMedia = media.count
                folders += result.folders.filter { seen.insert($0.ref).inserted }
                media += result.media.filter { seen.insert($0.ref).inserted }
                nextPage = result.nextPage
                isLoading = false
                onChange?(.appended(folders: firstFolder..<folders.count, media: firstMedia..<media.count))
            } catch {
                guard generation == self.generation else { return }
                self.error = error
                isLoading = false
                onChange?(.failed)
            }
        }
    }
}

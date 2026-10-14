// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

private final class StubPhotoProvider: PhotoProvider, @unchecked Sendable {
    var pages: [Int: Result<PhotoPage, Error>] = [:]
    var asked: [Int] = []

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> PhotoPage {
        asked.append(page.offset)
        return try (pages[page.offset] ?? .failure(MediaProviderError.notFound)).get()
    }
}

@MainActor
final class PhotoListingTests: XCTestCase {
    private let provider = StubPhotoProvider()
    private let library = MediaLibrary(id: "lib", providerID: "stub", title: "Photos", kind: .photos)
    private var changes: [PhotoListing.Change] = []

    private func item(_ id: String, _ kind: PhotoItem.Kind = .photo) -> PhotoItem {
        PhotoItem(ref: MediaItemRef(providerID: "stub", itemID: id), kind: kind, title: id, date: nil,
                  childCount: nil, thumbnail: nil, full: nil, playable: nil)
    }

    private func page(folders: [String] = [], media: [String], next: Int?) -> Result<PhotoPage, Error> {
        .success(PhotoPage(folders: folders.map { item($0, .folder) }, media: media.map { item($0) },
                           nextPage: next.map { Page(offset: $0, limit: PhotoListing.pageSize) }))
    }

    private func listing() -> PhotoListing {
        let listing = PhotoListing(folder: nil) { [provider, library] in (provider, library) }
        listing.onChange = { [weak self] in self?.changes.append($0) }
        return listing
    }

    func test_pagesAppendInOrder_andEndWhenThereIsNoNextPage() async {
        provider.pages = [0: page(folders: ["f1"], media: ["a", "b"], next: 200), 200: page(media: ["c"], next: nil)]
        let listing = listing()

        await listing.loadFirst()?.value
        XCTAssertEqual(listing.media.map(\.title), ["a", "b"])
        XCTAssertTrue(listing.hasMore)

        await listing.loadMore()?.value
        XCTAssertEqual(listing.media.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(listing.folders.map(\.title), ["f1"])
        XCTAssertFalse(listing.hasMore)
        XCTAssertNil(listing.loadMore(), "nothing left to ask for")
        XCTAssertEqual(provider.asked, [0, 200])

        guard case .appended(let folders, let media)? = changes.last else { return XCTFail("no append reported") }
        XCTAssertEqual(folders, 1..<1)
        XCTAssertEqual(media, 2..<3, "the grid inserts exactly these rows")
    }

    func test_aRefSeenTwice_isKeptOnce() async {
        provider.pages = [0: page(media: ["a", "b"], next: 200), 200: page(media: ["b", "c"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertEqual(listing.media.map(\.title), ["a", "b", "c"], "a duplicate row would crash the data source")
    }

    func test_foldersFromALaterPage_joinTheFolderList() async {
        provider.pages = [0: page(folders: ["f1"], media: ["a"], next: 200),
                          200: page(folders: ["f2"], media: ["b"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertEqual(listing.folders.map(\.title), ["f1", "f2"])
    }

    func test_aFailedLaterPage_keepsWhatIsLoaded_andCanBeRetried() async {
        provider.pages = [0: page(media: ["a"], next: 200)]
        let listing = listing()
        await listing.loadFirst()?.value

        await listing.loadMore()?.value
        XCTAssertNotNil(listing.error)
        XCTAssertEqual(listing.media.map(\.title), ["a"])
        XCTAssertTrue(listing.hasMore)
        XCTAssertFalse(listing.isLoading)

        provider.pages[200] = page(media: ["b"], next: nil)
        await listing.loadMore()?.value
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.media.map(\.title), ["a", "b"])
    }

    func test_loadFirst_startsOver() async {
        provider.pages = [0: page(media: ["a"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        provider.pages = [0: page(media: ["z"], next: nil)]
        await listing.loadFirst()?.value
        XCTAssertEqual(listing.media.map(\.title), ["z"])
    }

    func test_loadFirst_announcesTheReloadAsLoading_withTheOldErrorCleared() async {
        let listing = listing()
        await listing.loadFirst()?.value
        XCTAssertNotNil(listing.error)

        var seen: [(loading: Bool, failed: Bool)] = []
        listing.onChange = { [unowned listing] change in
            if case .reloaded = change { seen.append((listing.isLoading, listing.error != nil)) }
        }
        await listing.loadFirst()?.value
        XCTAssertEqual(seen.map(\.loading), [true], "an empty, idle listing reads as No Content")
        XCTAssertEqual(seen.map(\.failed), [false])
    }

    func test_withNoProvider_reportsAFailure() async {
        let listing = PhotoListing(folder: nil) { nil }
        await listing.loadFirst()?.value
        XCTAssertNotNil(listing.error)
        XCTAssertTrue(listing.media.isEmpty)
    }
}

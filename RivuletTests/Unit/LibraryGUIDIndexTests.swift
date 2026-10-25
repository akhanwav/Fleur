// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryGUIDIndexTests.swift
//  RivuletTests

import XCTest
@testable import Rivulet

final class LibraryGUIDIndexTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryGUIDIndexTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeIndex() -> LibraryGUIDIndex { LibraryGUIDIndex(cacheDirectory: directory) }

    private func section(_ key: String, _ items: [PlexMetadata], signature: String? = "sig",
                         fetchedAt: Date = Date()) -> LibraryGUIDIndex.Section {
        LibraryGUIDIndex.Section(key: key, serverID: "server", signature: signature, fetchedAt: fetchedAt,
                                 entries: items.compactMap(LibraryGUIDIndex.Entry.init))
    }

    func testParsesTMDBImdbTvdbGUIDs() async {
        var item = PlexMetadata(
            ratingKey: "1",
            guid: "plex://movie/abc",
            type: "movie",
            title: "Foo"
        )
        item.Guid = [
            PlexGuid(id: "tmdb://12345"),
            PlexGuid(id: "imdb://tt7654321"),
            PlexGuid(id: "tvdb://999")
        ]

        let index = makeIndex()
        await index.replace(with: [section("1", [item])], changed: ["1"])

        let byTmdb = await index.lookup(tmdbId: 12345, type: .movie)
        XCTAssertEqual(byTmdb?.ratingKey, "1")

        let byTmdbGuid = await index.lookup(guid: "tmdb://12345")
        XCTAssertEqual(byTmdbGuid?.ratingKey, "1")

        let byImdb = await index.lookup(guid: "imdb://tt7654321")
        XCTAssertEqual(byImdb?.ratingKey, "1")

        let byTvdb = await index.lookup(guid: "tvdb://999")
        XCTAssertEqual(byTvdb?.ratingKey, "1")
    }

    func testIgnoresItemsWithoutExternalGUIDs() async {
        let item = PlexMetadata(ratingKey: "1", guid: "plex://movie/abc", type: "movie", title: "Foo")
        let index = makeIndex()
        await index.replace(with: [section("1", [item])], changed: ["1"])

        let result = await index.lookup(tmdbId: 1, type: .movie)
        XCTAssertNil(result)
    }

    func testTypeAwareLookupSegregatesMovieFromTV() async {
        var movie = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        movie.Guid = [PlexGuid(id: "tmdb://100")]

        var show = PlexMetadata(ratingKey: "2", type: "show", title: "Bar")
        show.Guid = [PlexGuid(id: "tmdb://100")]

        let index = makeIndex()
        await index.replace(with: [section("1", [movie, show])], changed: ["1"])

        let movieMatch = await index.lookup(tmdbId: 100, type: .movie)
        XCTAssertEqual(movieMatch?.ratingKey, "1")

        let showMatch = await index.lookup(tmdbId: 100, type: .tv)
        XCTAssertEqual(showMatch?.ratingKey, "2")
    }

    func testReplaceClearsPreviousState() async {
        var item1 = PlexMetadata(ratingKey: "1", type: "movie", title: "A")
        item1.Guid = [PlexGuid(id: "tmdb://1")]

        var item2 = PlexMetadata(ratingKey: "2", type: "movie", title: "B")
        item2.Guid = [PlexGuid(id: "tmdb://2")]

        let index = makeIndex()
        await index.replace(with: [section("1", [item1])], changed: ["1"])
        await index.replace(with: [section("1", [item2])], changed: ["1"])

        let stale = await index.lookup(tmdbId: 1, type: .movie)
        XCTAssertNil(stale)

        let fresh = await index.lookup(tmdbId: 2, type: .movie)
        XCTAssertEqual(fresh?.ratingKey, "2")
    }

    func testReplacePopulatesTheInMemoryIndex() async {
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]

        let index = makeIndex()
        await index.replace(with: [section("1", [item])], changed: ["1"])

        let match = await index.lookup(tmdbId: 42, type: .movie)
        XCTAssertEqual(match?.ratingKey, "1")
    }

    func testLiveDataBlocksALateDiskHydrate() async {
        // A hydrateFromDisk() that finished after the network build must not
        // replace current server data with last launch's snapshot.
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]

        let index = makeIndex()
        await index.replace(with: [section("1", [item])], changed: ["1"])

        let hydrated = await index.hydrateFromDisk()
        XCTAssertEqual(hydrated, 0, "a late hydrate must be a no-op after any live build")

        let match = await index.lookup(tmdbId: 42, type: .movie)
        XCTAssertEqual(match?.ratingKey, "1")
    }

    func testEveryReplaceBumpsGeneration() async {
        // Consumers such as the trending hero skip recomputation when the
        // generation hasn't moved.
        var item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        item.Guid = [PlexGuid(id: "tmdb://42")]

        let index = makeIndex()
        let start = await index.generation

        await index.replace(with: [section("1", [item])], changed: ["1"])
        let afterFirst = await index.generation
        XCTAssertEqual(afterFirst, start + 1)

        await index.replace(with: [section("1", [item])], changed: ["1"])
        let afterSecond = await index.generation
        XCTAssertEqual(afterSecond, start + 2)
    }

    func testIgnoresNonMovieNonShowItems() async {
        var episode = PlexMetadata(ratingKey: "1", type: "episode", title: "Ep1")
        episode.Guid = [PlexGuid(id: "tmdb://500")]

        let index = makeIndex()
        await index.replace(with: [section("1", [episode])], changed: ["1"])

        // Episodes shouldn't be indexed by tmdbId — that index is movie/show only.
        let asMovie = await index.lookup(tmdbId: 500, type: .movie)
        XCTAssertNil(asMovie)

        let asTV = await index.lookup(tmdbId: 500, type: .tv)
        XCTAssertNil(asTV)
    }

    func testLookupKeepsTheFieldsTilesAndTheHeroShow() async {
        var item = PlexMetadata(
            ratingKey: "7", key: "/library/metadata/7", guid: "plex://movie/x", type: "movie",
            title: "Foo", contentRating: "PG-13", summary: "First. Second.", year: 2021,
            thumb: "/t", art: "/a", Genre: [PlexTag(_id: 1, tag: "Drama"), PlexTag(_id: 2, tag: "War")],
            duration: 5_400_000, librarySectionID: 9, viewOffset: 60_000, userRating: 10,
            Media: [
                PlexMedia(id: 1, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
                          audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: "4k",
                          container: nil, videoFrameRate: nil, Part: nil),
                PlexMedia(id: 2, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
                          audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: "1080",
                          container: nil, videoFrameRate: nil, Part: nil),
            ]
        )
        item.Guid = [PlexGuid(id: "tmdb://3"), PlexGuid(id: "imdb://tt3")]
        item.Role = [PlexRole(tag: "Someone")]

        let index = makeIndex()
        await index.replace(with: [section("1", [item])], changed: ["1"])

        let match = await index.lookup(guid: "imdb://tt3")
        XCTAssertEqual(match?.title, "Foo")
        XCTAssertEqual(match?.summary, "First. Second.")
        XCTAssertEqual(match?.contentRating, "PG-13")
        XCTAssertEqual(match?.Genre?.map(\.tag), ["Drama"])
        XCTAssertEqual(match?.librarySectionID, 9)
        XCTAssertEqual(match?.viewOffset, 60_000)
        XCTAssertEqual(match?.tmdbId, 3)
        XCTAssertEqual(match?.Media.map { Set($0.map(\.id)).count }, 2)
        XCTAssertNil(match?.Role, "cast is not part of an entry")
    }

    func testSavedSectionsLoadIntoAFreshIndex() async {
        var movie = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        movie.Guid = [PlexGuid(id: "tmdb://42")]
        var show = PlexMetadata(ratingKey: "2", type: "show", title: "Bar")
        show.Guid = [PlexGuid(id: "tvdb://7")]
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let writer = makeIndex()
        await writer.replace(with: [section("9", [movie], signature: "a", fetchedAt: fetchedAt),
                                    section("15", [show], signature: "b", fetchedAt: fetchedAt)],
                             changed: ["9", "15"])
        await writer.waitForPendingWrites()

        let reader = makeIndex()
        let hydrated = await reader.hydrateFromDisk()
        XCTAssertEqual(hydrated, 2)
        let movieMatch = await reader.lookup(tmdbId: 42, type: .movie)
        XCTAssertEqual(movieMatch?.title, "Foo")
        let showMatch = await reader.lookup(guid: "tvdb://7")
        XCTAssertEqual(showMatch?.ratingKey, "2")
        let stored = await reader.storedSections()
        XCTAssertEqual(stored["15"]?.signature, "b")
        XCTAssertEqual(stored["15"]?.serverID, "server")
        XCTAssertEqual(stored["9"]?.fetchedAt, fetchedAt)
    }

    func testOnlyChangedSectionsAreWrittenAndDroppedOnesDeleted() async throws {
        var a = PlexMetadata(ratingKey: "1", type: "movie", title: "A")
        a.Guid = [PlexGuid(id: "tmdb://1")]
        var b = PlexMetadata(ratingKey: "2", type: "movie", title: "B")
        b.Guid = [PlexGuid(id: "tmdb://2")]

        let index = makeIndex()
        await index.replace(with: [section("1", [a]), section("2", [b])], changed: ["1", "2"])
        await index.waitForPendingWrites()
        // Section 2 is gone (library hidden); section 1 is unchanged.
        await index.replace(with: [section("1", [a])], changed: [])
        await index.waitForPendingWrites()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["section-1.ndjson"])
    }

    func testATruncatedSectionFileIsIgnored() async throws {
        var items: [PlexMetadata] = []
        for i in 0..<4500 {
            var item = PlexMetadata(ratingKey: "\(i)", type: "movie", title: "T\(i)")
            item.Guid = [PlexGuid(id: "tmdb://\(i)")]
            items.append(item)
        }
        let writer = makeIndex()
        await writer.replace(with: [section("1", items)], changed: ["1"])
        await writer.waitForPendingWrites()

        // Cut the last chunk off, as an interrupted write would.
        let file = directory.appendingPathComponent("section-1.ndjson")
        let data = try Data(contentsOf: file)
        let lines = data.split(separator: 0x0A)
        try Data(lines.dropLast().joined(separator: [0x0A])).write(to: file)

        let reader = makeIndex()
        let hydrated = await reader.hydrateFromDisk()
        XCTAssertEqual(hydrated, 0, "a section with fewer entries than its header must be read again")
    }
}

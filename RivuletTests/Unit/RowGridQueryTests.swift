import XCTest
@testable import Rivulet

/// A View All grid pages the row's own key until a sort or filter differs,
/// then the library listing behind the row, filtered by Plex.
final class RowGridQueryTests: XCTestCase {

    private func params(_ key: String) -> [String: [String]] {
        let items = URLComponents(string: key)?.queryItems ?? []
        return Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value) }
    }

    func test_unchanged_pagesTheRowsOwnKey() {
        let q = RowGridQuery(rowKey: "/hubs/home/recentlyAdded?type=1", rowIdentifier: "home.movies.recent")
        XCTAssertEqual(q.key(for: .init()), "/hubs/home/recentlyAdded?type=1")
    }

    func test_libraryRow_keepsItsFilters_andTakesTheNewSort() {
        let q = RowGridQuery(rowKey: "/library/sections/5/all?unwatched=1&audienceRating>=7.0&sort=audienceRating:desc",
                             rowIdentifier: nil, libraryType: { _ in .movie })
        XCTAssertEqual(q.rowSortName, "Rating")
        let key = q.key(for: .init(sort: .title))
        XCTAssertTrue(key.hasPrefix("/library/sections/5/all?"))
        let p = params(key)
        XCTAssertEqual(p["unwatched"], ["1"])
        XCTAssertEqual(p["audienceRating>"], ["7.0"])
        XCTAssertEqual(p["sort"], ["titleSort"])
        XCTAssertEqual(p["type"], ["1"])
    }

    func test_homeRecentlyAdded_filtersAcrossLibraries_newestFirst() {
        let q = RowGridQuery(rowKey: "/hubs/home/recentlyAdded?type=1", rowIdentifier: nil)
        XCTAssertEqual(q.rowSortName, "Date Added")
        let key = q.key(for: .init(quality: .uhd))
        XCTAssertTrue(key.hasPrefix("/library/all?"))
        let p = params(key)
        XCTAssertEqual(p["sort"], ["addedAt:desc"])
        XCTAssertEqual(p["resolution"], ["4k"])
        XCTAssertEqual(p["type"], ["1"])
    }

    func test_libraryRecentlyAdded_staysInItsLibrary() {
        let q = RowGridQuery(rowKey: "/hubs/home/recentlyAdded?type=2&sectionID=4", rowIdentifier: nil)
        XCTAssertTrue(q.key(for: .init(sort: .year)).hasPrefix("/library/sections/4/all?"))
        XCTAssertEqual(params(q.key(for: .init(sort: .year)))["sort"], ["year:desc"])
    }

    /// A TV row mixes seasons and episodes, a show once per addition: its
    /// grid lists the library's shows by newest episode, each once.
    func test_tvRecentlyAdded_opensOnShowsByNewestEpisode() {
        let q = RowGridQuery(rowKey: "/hubs/home/recentlyAdded?type=2&sectionID=22", rowIdentifier: nil)
        let key = q.key(for: .init())
        XCTAssertTrue(key.hasPrefix("/library/sections/22/all?"))
        XCTAssertEqual(params(key)["sort"], ["episode.addedAt:desc"])
        XCTAssertEqual(params(key)["type"], ["2"])
        XCTAssertEqual(q.rowSortName, "Date Added")
    }

    /// Repeated, not comma-joined: Plex reads a repeat as AND.
    func test_genres_areRepeated() {
        let q = RowGridQuery(rowKey: "/library/sections/5/all?sort=addedAt:desc", rowIdentifier: nil,
                             libraryType: { _ in .movie })
        let choices = RowGridQuery.Choices(genres: [.init(id: "9", title: "Horror"), .init(id: "1773", title: "Comedy")])
        XCTAssertEqual(params(q.key(for: choices))["genre"], ["1773", "9"])
    }

    /// Episodes filter by their show's genre; shows by their episodes' quality.
    func test_tvFields() {
        let q = RowGridQuery(rowKey: "/hubs/home/recentlyAdded?type=2&sectionID=4", rowIdentifier: nil)
        XCTAssertEqual(q.typeOptions, [.show, .episode])
        let genre = RowGridQuery.Genre(id: "11", title: "Drama")
        let shows = params(q.key(for: .init(genres: [genre], quality: .uhd)))
        XCTAssertEqual(shows["genre"], ["11"])
        XCTAssertEqual(shows["episode.resolution"], ["4k"])
        let episodes = params(q.key(for: .init(type: .episode, genres: [genre], quality: .uhd)))
        XCTAssertEqual(episodes["type"], ["4"])
        XCTAssertEqual(episodes["show.genre"], ["11"])
        XCTAssertEqual(episodes["resolution"], ["4k"])
        XCTAssertEqual(q.genreType(for: .init(type: .episode)), .show)
    }

    /// A curated hub has no listing: Plex ignores filters on hub endpoints.
    func test_curatedHub_cannotFilter() {
        let q = RowGridQuery(rowKey: "/hubs/items?identifier=movie.curated.5.1&curatedHubSeed=1", rowIdentifier: "movie.curated.5.1")
        XCTAssertFalse(q.canFilter)
        XCTAssertEqual(q.key(for: .init(sort: .title)), q.rowKey)
        XCTAssertEqual(q.rowSortName, "Default")
    }

    func test_personalMediaRow_cannotFilter() {
        XCTAssertFalse(RowGridQuery(rowKey: "/hubs/home/recentlyAdded?type=1&personal=1", rowIdentifier: nil).canFilter)
    }

    private func movie(_ title: String, year: Int?, sortTitle: String? = nil) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "plex:a", itemID: title), kind: .movie, title: title,
                  sortTitle: sortTitle, overview: nil, year: year, runtime: nil, parentRef: nil, grandparentRef: nil,
                  episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }

    func test_sortedInApp() {
        let items = [movie("The Witch", year: 2015, sortTitle: "Witch"), movie("Alien", year: 1979),
                     movie("Brazil", year: nil), movie("Arrival", year: 2016)]
        XCTAssertEqual(RowGridQuery.sortedInApp(items, by: .title).map(\.title), ["Alien", "Arrival", "Brazil", "The Witch"])
        XCTAssertEqual(RowGridQuery.sortedInApp(items, by: .year).map(\.title), ["Arrival", "The Witch", "Alien", "Brazil"])
        XCTAssertEqual(RowGridQuery.sortedInApp(items, by: .row).map(\.title), items.map(\.title))
    }

    func test_movieRow_hasNoTypeChoice() {
        let q = RowGridQuery(rowKey: "/library/sections/5/all?sort=addedAt:desc", rowIdentifier: nil,
                             libraryType: { _ in .movie })
        XCTAssertTrue(q.typeOptions.isEmpty)
    }
}

/// A paging row shows 15 tiles; more than 15 in its source adds View All.
final class RowCapTests: XCTestCase {
    func test_moreThanFifteen_capsAndAddsViewAll() {
        let capped = RowCap.capped(Array(0..<24), total: nil)
        XCTAssertEqual(capped.items, Array(0..<15))
        XCTAssertTrue(capped.viewAll)
    }

    func test_serverTotal_countsPagesNotYetLoaded() {
        XCTAssertTrue(RowCap.capped(Array(0..<10), total: 67).viewAll)
    }

    func test_fifteenOrFewer_noViewAll() {
        XCTAssertFalse(RowCap.capped(Array(0..<15), total: 15).viewAll)
        XCTAssertFalse(RowCap.capped(Array(0..<8), total: nil).viewAll)
    }
}

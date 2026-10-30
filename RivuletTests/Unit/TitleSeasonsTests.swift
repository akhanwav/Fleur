import XCTest
@testable import Rivulet

/// A Recently Added show names the latest season that came in.
final class TitleSeasonsTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func season(_ number: Int, addedDaysAgo days: Double?) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "plex:a", itemID: "s\(number)"), kind: .season, title: "Season \(number)",
                  sortTitle: nil, overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                  episodeNumber: nil, seasonNumber: number, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil,
                  addedAt: days.map { now.addingTimeInterval(-$0 * day) })
    }

    func test_oneNewSeason() {
        let seasons = [season(1, addedDaysAgo: 400), season(2, addedDaysAgo: 200), season(3, addedDaysAgo: 2)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Season 3")
    }

    func test_aWholeShowAddedAtOnce_namesItsLatestSeason() {
        let seasons = [season(1, addedDaysAgo: 3), season(2, addedDaysAgo: 3), season(3, addedDaysAgo: 2.5)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Season 3")
    }

    func test_specialsAreLeftOut() {
        let seasons = [season(0, addedDaysAgo: 1), season(1, addedDaysAgo: 300), season(2, addedDaysAgo: 1)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Season 2")
    }

    func test_twoNewSeasons_theLaterOne() {
        let seasons = [season(2, addedDaysAgo: 1), season(3, addedDaysAgo: 90), season(4, addedDaysAgo: 1.2)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Season 4")
    }

    /// Gintama on Sesama: four seasons added minutes apart, not in order.
    func test_seasonsAddedOutOfOrder_theHighest() {
        let seasons = [season(1, addedDaysAgo: 1.01), season(2, addedDaysAgo: 1.0), season(3, addedDaysAgo: 0.99),
                       season(4, addedDaysAgo: 1.005)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Season 4")
    }

    func test_noDates_noLabel() {
        XCTAssertNil(TitleSeasons.recentLabel(seasons: [season(1, addedDaysAgo: nil)]))
    }
}

/// A Recently Added row keeps the newest tile of each show.
final class RecentlyAddedRowTests: XCTestCase {
    private func item(_ id: String, _ kind: MediaKind, parent: String? = nil, grandparent: String? = nil) -> MediaItem {
        func ref(_ id: String?) -> MediaItemRef? { id.map { MediaItemRef(providerID: "plex:a", itemID: $0) } }
        return MediaItem(ref: ref(id)!, kind: kind, title: id, sortTitle: nil, overview: nil, year: nil, runtime: nil,
                         parentRef: ref(parent), grandparentRef: ref(grandparent),
                         episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                         userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                         artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                         parentArtwork: nil, grandparentArtwork: nil)
    }

    /// One Piece as listed on Sesama: episodes, then its season, then an older season's episode.
    func test_oneTilePerShow_theNewest() {
        let row = [item("op-e25", .episode, parent: "op-s23", grandparent: "op"),
                   item("gintama", .show),
                   item("op-e22", .episode, parent: "op-s23", grandparent: "op"),
                   item("op-s23", .season, parent: "op"),
                   item("op-e49", .episode, parent: "op-s22", grandparent: "op"),
                   item("bx-e131", .episode, parent: "bx-s1", grandparent: "bx"),
                   item("bx-s1", .season, parent: "bx")]
        XCTAssertEqual(RecentlyAddedRow.newestPerShow(row).map(\.ref.itemID), ["op-e25", "gintama", "bx-e131"])
    }

    func test_moviesAreTheirOwn() {
        let row = [item("m1", .movie), item("m2", .movie)]
        XCTAssertEqual(RecentlyAddedRow.newestPerShow(row).count, 2)
    }
}

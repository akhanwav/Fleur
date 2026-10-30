import XCTest
@testable import Rivulet

/// A Recently Added show names the seasons that came in last.
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

    func test_aWholeShowAddedAtOnce_isARun() {
        let seasons = [season(1, addedDaysAgo: 3), season(2, addedDaysAgo: 3), season(3, addedDaysAgo: 2.5)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Seasons 1–3")
    }

    func test_specialsAreLeftOut() {
        let seasons = [season(0, addedDaysAgo: 1), season(1, addedDaysAgo: 300), season(2, addedDaysAgo: 1)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Season 2")
    }

    func test_aGap_listsTheSeasons() {
        let seasons = [season(2, addedDaysAgo: 1), season(3, addedDaysAgo: 90), season(4, addedDaysAgo: 1.2)]
        XCTAssertEqual(TitleSeasons.recentLabel(seasons: seasons), "Seasons 2, 4")
    }

    func test_noDates_noLabel() {
        XCTAssertNil(TitleSeasons.recentLabel(seasons: [season(1, addedDaysAgo: nil)]))
    }
}

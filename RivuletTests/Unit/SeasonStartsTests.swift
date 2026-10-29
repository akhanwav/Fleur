import XCTest
@testable import Rivulet

/// A Recently Added episode tile opens its season's first episode while
/// nothing in that season has been watched or started.
final class SeasonStartsTests: XCTestCase {

    private func episode(_ number: Int, played: Bool = false, offset: TimeInterval = 0) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "plex:a", itemID: "e\(number)"), kind: .episode, title: "E\(number)",
                  sortTitle: nil, overview: nil, year: nil, runtime: 1_800, parentRef: nil, grandparentRef: nil,
                  episodeNumber: number, seasonNumber: 2, childProgress: nil,
                  userState: MediaUserState(isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }

    func test_untouchedSeason_opensItsFirstEpisode() {
        let season = [episode(3), episode(1), episode(2)]
        XCTAssertEqual(SeasonStarts.seasonStart(in: season, for: episode(3))?.ref.itemID, "e1")
    }

    func test_aWatchedEpisodeInTheSeason_keepsTheTile() {
        let season = [episode(1, played: true), episode(2), episode(3)]
        XCTAssertNil(SeasonStarts.seasonStart(in: season, for: episode(3)))
    }

    func test_aStartedEpisodeInTheSeason_keepsTheTile() {
        let season = [episode(1, offset: 120), episode(2), episode(3)]
        XCTAssertNil(SeasonStarts.seasonStart(in: season, for: episode(3)))
    }

    func test_theTileIsAlreadyTheFirst_keepsIt() {
        XCTAssertNil(SeasonStarts.seasonStart(in: [episode(1), episode(2)], for: episode(1)))
    }

    /// The episode list is from the season's own children; a tile already
    /// watched is not a fresh season.
    func test_aWatchedTile_keepsIt() {
        XCTAssertNil(SeasonStarts.seasonStart(in: [episode(1), episode(2)], for: episode(2, played: true)))
    }
}

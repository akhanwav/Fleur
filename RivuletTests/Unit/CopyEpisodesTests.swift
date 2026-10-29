import XCTest
@testable import Rivulet

/// A show page switched to another copy lists that copy's episodes, with the
/// page's own episodes it lacks greyed out.
final class CopyEpisodesTests: XCTestCase {

    private func item(_ id: String, kind: MediaKind, server: String, season: Int?, episode: Int? = nil,
                      parent: MediaItemRef? = nil, offset: TimeInterval = 0) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: server, itemID: id), kind: kind, title: id, sortTitle: nil,
                  overview: nil, year: nil, runtime: nil, parentRef: parent, grandparentRef: nil,
                  episodeNumber: episode, seasonNumber: season, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }

    private let mainS1 = MediaItemRef(providerID: "plex:main", itemID: "m-s1")
    private let mainS2 = MediaItemRef(providerID: "plex:main", itemID: "m-s2")
    private let alphaS1 = MediaItemRef(providerID: "plex:alpha", itemID: "a-s1")

    private var originalSeasons: [MediaItem] {
        [item("m-s1", kind: .season, server: "plex:main", season: 1),
         item("m-s2", kind: .season, server: "plex:main", season: 2)]
    }
    private var original: [MediaItem] {
        [item("m1", kind: .episode, server: "plex:main", season: 1, episode: 1, parent: mainS1),
         item("m2", kind: .episode, server: "plex:main", season: 1, episode: 2, parent: mainS1),
         item("m3", kind: .episode, server: "plex:main", season: 2, episode: 1, parent: mainS2)]
    }

    /// The copy's own episodes, with its own watch state, are the ones listed.
    func test_listsTheCopysOwnEpisodes() {
        let copy = [item("a1", kind: .episode, server: "plex:alpha", season: 1, episode: 1, parent: alphaS1, offset: 300),
                    item("a2", kind: .episode, server: "plex:alpha", season: 1, episode: 2, parent: alphaS1)]
        let merged = CopyEpisodes.merge(
            copy: copy, copySeasons: [item("a-s1", kind: .season, server: "plex:alpha", season: 1)],
            original: Array(original.prefix(2)), originalSeasons: [originalSeasons[0]])
        XCTAssertEqual(merged.episodes.map(\.ref.itemID), ["a1", "a2"])
        XCTAssertEqual(merged.episodes.first?.ref.providerID, "plex:alpha")
        XCTAssertEqual(merged.episodes.first?.userState.viewOffset, 300)
        XCTAssertTrue(merged.missing.isEmpty)
    }

    /// An episode only the original has is listed as missing, in order, under
    /// the copy's season of the same number; a season the copy lacks is added.
    func test_missingEpisodes_stayInOrder_underTheCopysSeason() {
        let copy = [item("a2", kind: .episode, server: "plex:alpha", season: 1, episode: 2, parent: alphaS1)]
        let merged = CopyEpisodes.merge(
            copy: copy, copySeasons: [item("a-s1", kind: .season, server: "plex:alpha", season: 1)],
            original: original, originalSeasons: originalSeasons)
        XCTAssertEqual(merged.episodes.map(\.ref.itemID), ["m1", "a2", "m3"])
        XCTAssertEqual(merged.missing, ["m1", "m3"])
        // S1E1 joins the copy's season 1; S2E1 keeps its own, which is listed.
        XCTAssertEqual(merged.episodes[0].parentRef, alphaS1)
        XCTAssertEqual(merged.episodes[2].parentRef, mainS2)
        XCTAssertEqual(merged.seasons.map(\.ref.itemID), ["a-s1", "m-s2"])
    }

    /// Episodes the copy has beyond the original's are listed too.
    func test_copyOnlyEpisodes_areListed() {
        let copy = [item("a1", kind: .episode, server: "plex:alpha", season: 1, episode: 1, parent: alphaS1),
                    item("a3", kind: .episode, server: "plex:alpha", season: 1, episode: 3, parent: alphaS1)]
        let merged = CopyEpisodes.merge(copy: copy, copySeasons: [], original: Array(original.prefix(1)),
                                        originalSeasons: [])
        XCTAssertEqual(merged.episodes.map(\.ref.itemID), ["a1", "a3"])
        XCTAssertTrue(merged.missing.isEmpty)
    }

    /// An original episode without a number cannot be matched: not listed.
    func test_unnumberedOriginalEpisodes_areLeftOut() {
        let copy = [item("a1", kind: .episode, server: "plex:alpha", season: 1, episode: 1, parent: alphaS1)]
        let loose = item("x", kind: .episode, server: "plex:main", season: nil, episode: nil)
        let merged = CopyEpisodes.merge(copy: copy, copySeasons: [], original: [loose], originalSeasons: [])
        XCTAssertEqual(merged.episodes.map(\.ref.itemID), ["a1"])
    }
}

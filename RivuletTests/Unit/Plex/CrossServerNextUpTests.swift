import XCTest
@testable import Rivulet

/// Continue Watching's episode for a show watched on several servers: one pick
/// from every server's history, one card per quality.
final class CrossServerNextUpTests: XCTestCase {

    private let show = "plex://show/yaga"
    /// Every activity in these tests is inside the 16-week window unless it says otherwise.
    private let now = Date(timeIntervalSince1970: 1_000)

    private func ep(_ season: Int, _ number: Int, key: String, watched: Bool = false, offset: Int = 0,
                    viewed: Int? = nil, added: Int = 0, resolution: String = "1080") -> PlexMetadata {
        var item = PlexMetadata(ratingKey: key, type: "episode", title: "S\(season)E\(number)")
        item.parentIndex = season
        item.index = number
        item.viewCount = watched ? 1 : 0
        item.viewOffset = offset
        item.lastViewedAt = viewed
        item.addedAt = added
        item.grandparentGuid = show
        item.Media = [PlexMedia(id: 1, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
                                audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: resolution,
                                container: nil, videoFrameRate: nil, Part: nil)]
        return item
    }

    private func server(_ id: String, viewed: Int, _ episodes: [PlexMetadata]) -> CrossServerNextUp.ServerShow {
        .init(providerID: id, lastViewedAt: viewed, episodes: episodes)
    }

    private func cards(_ outcome: CrossServerNextUp.Outcome) -> [CrossServerNextUp.Card] {
        if case .cards(let cards) = outcome { return cards }
        return []
    }

    /// Yaga: S1E1 and S1E2 watched on Alpha; Sesama, written to by the old
    /// wrong-server bug, has only S1E1 and offers S1E2. No S1E3 anywhere.
    func test_watchedThroughTheLastEpisodeOnAnotherServer_isNoCard() {
        let alpha = server("plex:alpha", viewed: 200, [
            ep(1, 1, key: "a1", watched: true, viewed: 100), ep(1, 2, key: "a2", watched: true, viewed: 200)])
        let sesama = server("plex:sesama", viewed: 150, [
            ep(1, 1, key: "s1", watched: true, viewed: 150), ep(1, 2, key: "s2")])
        guard case .caughtUp = CrossServerNextUp.outcome(showGuid: show, servers: [sesama, alpha], now: now) else {
            return XCTFail("an episode already watched on Alpha was offered")
        }
    }

    /// The next episode exists only on a server the show was not watched on.
    func test_nextEpisode_onlyOnAnotherServer() {
        let alpha = server("plex:alpha", viewed: 200, [
            ep(1, 1, key: "a1", watched: true, viewed: 100), ep(1, 2, key: "a2", watched: true, viewed: 200)])
        let sesama = server("plex:sesama", viewed: 0, [ep(1, 1, key: "s1"), ep(1, 2, key: "s2"), ep(1, 3, key: "s3")])
        let picked = cards(CrossServerNextUp.outcome(showGuid: show, servers: [sesama, alpha], now: now))
        XCTAssertEqual(picked.map(\.providerID), ["plex:sesama"])
        XCTAssertEqual(picked.first?.meta.ratingKey, "s3")
        XCTAssertEqual(picked.first?.meta.viewOffset, 0)
        // Sorted with the show's latest watch anywhere.
        XCTAssertEqual(picked.first?.meta.lastViewedAt, 200)
    }

    /// Never an earlier unwatched episode when a later one has been watched.
    func test_skipsAnEarlierUnwatchedEpisode() {
        let a = server("plex:a", viewed: 300, [
            ep(1, 1, key: "1", watched: true, viewed: 100), ep(1, 2, key: "2"),
            ep(1, 3, key: "3", watched: true, viewed: 300), ep(1, 4, key: "4")])
        XCTAssertEqual(cards(CrossServerNextUp.outcome(showGuid: show, servers: [a], now: now)).first?.meta.ratingKey, "4")
    }

    /// The most recent activity is a partly watched episode: resume it, there.
    func test_resumesTheMostRecentPartlyWatchedEpisode() {
        let a = server("plex:a", viewed: 100, [ep(1, 1, key: "a1", watched: true, viewed: 100), ep(1, 2, key: "a2")])
        let b = server("plex:b", viewed: 500, [ep(1, 1, key: "b1"), ep(1, 2, key: "b2", offset: 90_000, viewed: 500)])
        let picked = cards(CrossServerNextUp.outcome(showGuid: show, servers: [a, b], now: now))
        XCTAssertEqual(picked.map(\.providerID), ["plex:b"])
        XCTAssertEqual(picked.first?.meta.ratingKey, "b2")
        XCTAssertEqual(picked.first?.meta.viewOffset, 90_000)
    }

    /// A rewatch: the whole show watched on one server, then an earlier
    /// episode partway through on another, most recently. Resume it.
    func test_rewatch_resumesEvenWhenTheShowIsFinishedElsewhere() {
        let a = server("plex:a", viewed: 300, [
            ep(1, 1, key: "a1", watched: true, viewed: 100), ep(1, 2, key: "a2", watched: true, viewed: 300)])
        let b = server("plex:b", viewed: 900, [ep(1, 1, key: "b1", offset: 120_000, viewed: 900), ep(1, 2, key: "b2")])
        let picked = cards(CrossServerNextUp.outcome(showGuid: show, servers: [a, b], now: now))
        XCTAssertEqual(picked.map(\.providerID), ["plex:b"])
        XCTAssertEqual(picked.first?.meta.ratingKey, "b1")
        XCTAssertEqual(picked.first?.meta.viewOffset, 120_000)
    }

    /// The same rewatch more than 16 weeks ago stays hidden: the show is caught up.
    func test_rewatch_olderThanTheWindow_staysHidden() {
        let later = Date(timeIntervalSince1970: 900 + CrossServerNextUp.window + 1)
        let a = server("plex:a", viewed: 300, [
            ep(1, 1, key: "a1", watched: true, viewed: 100), ep(1, 2, key: "a2", watched: true, viewed: 300)])
        let b = server("plex:b", viewed: 900, [ep(1, 1, key: "b1", offset: 120_000, viewed: 900), ep(1, 2, key: "b2")])
        guard case .caughtUp = CrossServerNextUp.outcome(showGuid: show, servers: [a, b], now: later) else {
            return XCTFail("a rewatch older than the window was offered")
        }
    }

    /// Only an old partial watch and nothing finished: Plex's own window decides.
    func test_onlyAnOldPartialWatch_leavesPlexsOwnEntries() {
        let later = Date(timeIntervalSince1970: 900 + CrossServerNextUp.window + 1)
        let a = server("plex:a", viewed: 900, [ep(1, 1, key: "a1", offset: 60_000, viewed: 900), ep(1, 2, key: "a2")])
        guard case .noHistory = CrossServerNextUp.outcome(showGuid: show, servers: [a], now: later) else {
            return XCTFail("an old partial watch was decided")
        }
    }

    /// A rewatch left partway, then later episodes finished elsewhere: the
    /// later watch wins, so the show moves on.
    func test_anOlderPartialWatch_givesWayToALaterOne() {
        let a = server("plex:a", viewed: 100, [ep(1, 1, key: "a1", offset: 30_000, viewed: 100)])
        let b = server("plex:b", viewed: 900, [
            ep(1, 1, key: "b1", watched: true, viewed: 800), ep(1, 2, key: "b2", watched: true, viewed: 900),
            ep(1, 3, key: "b3")])
        XCTAssertEqual(cards(CrossServerNextUp.outcome(showGuid: show, servers: [a, b], now: now)).first?.meta.ratingKey, "b3")
    }

    /// The last episode of a season leads to the next season's first.
    func test_crossesIntoTheNextSeason() {
        let a = server("plex:a", viewed: 100, [
            ep(1, 10, key: "1x10", watched: true, viewed: 100), ep(2, 1, key: "2x1"), ep(2, 2, key: "2x2")])
        XCTAssertEqual(cards(CrossServerNextUp.outcome(showGuid: show, servers: [a], now: now)).first?.meta.ratingKey, "2x1")
    }

    /// One card per quality, each on the server the show was watched on most
    /// recently among those holding it; a tie keeps the order given.
    func test_oneCardPerQuality_onTheMostRecentlyWatchedServer() {
        let main = server("plex:main", viewed: 100, [
            ep(1, 1, key: "m1", watched: true, viewed: 100), ep(1, 2, key: "m2-4k", resolution: "4k"),
            ep(1, 2, key: "m2-hd", resolution: "1080")])
        let alpha = server("plex:alpha", viewed: 400, [
            ep(1, 1, key: "a1", watched: true, viewed: 400), ep(1, 2, key: "a2-hd", resolution: "1080")])
        let picked = cards(CrossServerNextUp.outcome(showGuid: show, servers: [main, alpha], now: now))
        XCTAssertEqual(Set(picked.map { $0.meta.ratingKey ?? "" }), ["m2-4k", "a2-hd"])
    }

    func test_neverWatched_leavesPlexsOwnEntries() {
        let a = server("plex:a", viewed: 0, [ep(1, 1, key: "1"), ep(1, 2, key: "2")])
        guard case .noHistory = CrossServerNextUp.outcome(showGuid: show, servers: [a], now: now) else {
            return XCTFail("a show never watched was decided")
        }
    }

    /// Specials are not part of the order.
    func test_specialsAreLeftOut() {
        let a = server("plex:a", viewed: 100, [ep(0, 1, key: "sp", watched: true, viewed: 100), ep(1, 1, key: "1")])
        guard case .noHistory = CrossServerNextUp.outcome(showGuid: show, servers: [a], now: now) else {
            return XCTFail("a watched special counted as progress")
        }
    }

    // MARK: - Which seasons to read

    func test_furthestSeason_fromWatchedSeasonsAndPartialEntries() {
        func season(_ index: Int, viewed: Int) -> PlexMetadata {
            var item = PlexMetadata(ratingKey: "s\(index)", type: "season", title: "Season \(index)")
            item.index = index
            item.viewedLeafCount = viewed
            return item
        }
        let seasons = [season(0, viewed: 3), season(1, viewed: 10), season(2, viewed: 0), season(3, viewed: 0)]
        XCTAssertEqual(CrossServerNextUp.furthestSeason(seasons: seasons, entries: []), 1)
        XCTAssertEqual(CrossServerNextUp.furthestSeason(seasons: seasons, entries: [ep(2, 4, key: "p", offset: 5)]), 2)
        XCTAssertNil(CrossServerNextUp.furthestSeason(seasons: [season(1, viewed: 0)], entries: []))
    }

    func test_seasonsToFetch_theFurthestAndTheNextHeld() {
        XCTAssertEqual(CrossServerNextUp.seasonsToFetch(furthest: 2, available: [1, 2, 4]), [2, 4])
        XCTAssertEqual(CrossServerNextUp.seasonsToFetch(furthest: 2, available: [1, 3]), [3])
        XCTAssertEqual(CrossServerNextUp.seasonsToFetch(furthest: 5, available: [1, 2]), [])
    }

    // MARK: - Applying to the row

    func test_applying_caughtUpRemovesTheShowsEntries() {
        let lists: [(providerID: String, metas: [PlexMetadata])] = [
            ("plex:sesama", [ep(1, 2, key: "s2"), PlexMetadata(ratingKey: "m", type: "movie", title: "Movie")])]
        let result = PlexDataStore.applying([show: .caughtUp], to: lists)
        XCTAssertEqual(result.first?.compactMap(\.ratingKey), ["m"])
    }

    func test_applying_cardsReplaceEveryServersEntries() {
        let card = CrossServerNextUp.Card(providerID: "plex:alpha", meta: ep(1, 3, key: "a3"))
        let lists: [(providerID: String, metas: [PlexMetadata])] = [
            ("plex:main", [ep(1, 2, key: "m2")]), ("plex:alpha", [ep(1, 1, key: "a1", offset: 10)])]
        let result = PlexDataStore.applying([show: .cards([card])], to: lists)
        XCTAssertEqual(result.map { $0.compactMap(\.ratingKey) }, [[], ["a3"]])
    }

    /// A card for a server not in the row (its list failed) cannot be shown,
    /// so the show keeps Plex's own entries rather than vanishing.
    func test_applying_cardsForNoListedServer_keepTheEntries() {
        let card = CrossServerNextUp.Card(providerID: "plex:gone", meta: ep(1, 3, key: "g3"))
        let lists: [(providerID: String, metas: [PlexMetadata])] = [("plex:main", [ep(1, 2, key: "m2")])]
        XCTAssertEqual(PlexDataStore.applying([show: .cards([card])], to: lists).first?.compactMap(\.ratingKey), ["m2"])
    }

    func test_applying_noHistoryChangesNothing() {
        let lists: [(providerID: String, metas: [PlexMetadata])] = [("plex:main", [ep(1, 2, key: "m2")])]
        XCTAssertEqual(PlexDataStore.applying([show: .noHistory], to: lists).first?.compactMap(\.ratingKey), ["m2"])
    }

    // MARK: - New Episode tag

    private func item(added: Date?, watched: Date?, offset: TimeInterval = 0, kind: MediaKind = .episode) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "plex:a", itemID: "1"), kind: kind, title: "E", sortTitle: nil,
                  overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                  episodeNumber: 1, seasonNumber: 1, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: offset, isFavorite: false, lastViewedAt: watched),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil, addedAt: added)
    }

    func test_newEpisodeTag() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let day: TimeInterval = 86_400
        // Added after the show was last watched, two days ago.
        XCTAssertTrue(NewEpisodeTag.applies(to: item(added: now - 2 * day, watched: now - 5 * day), now: now))
        // More than a week old.
        XCTAssertFalse(NewEpisodeTag.applies(to: item(added: now - 8 * day, watched: now - 9 * day), now: now))
        // Added before the last watch: the person is mid-season, not caught up.
        XCTAssertFalse(NewEpisodeTag.applies(to: item(added: now - 2 * day, watched: now - day), now: now))
        // Started already, a movie, or a show never watched.
        XCTAssertFalse(NewEpisodeTag.applies(to: item(added: now - day, watched: now - 2 * day, offset: 60), now: now))
        XCTAssertFalse(NewEpisodeTag.applies(to: item(added: now - day, watched: now - 2 * day, kind: .movie), now: now))
        XCTAssertFalse(NewEpisodeTag.applies(to: item(added: now - day, watched: nil), now: now))
    }
}

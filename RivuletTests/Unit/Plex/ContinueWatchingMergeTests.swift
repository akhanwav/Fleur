// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Home's Continue Watching across servers: one card per title, the most
/// recently watched copy, newest first.
final class ContinueWatchingMergeTests: XCTestCase {

    private func movie(_ guid: String, viewed: Int, key: String = "1") -> PlexMetadata {
        var item = PlexMetadata(ratingKey: key, type: "movie", title: guid)
        item.guid = guid
        item.lastViewedAt = viewed
        return item
    }

    private func episode(show: String, viewed: Int, key: String = "1") -> PlexMetadata {
        var item = PlexMetadata(ratingKey: key, type: "episode", title: "Episode")
        item.grandparentGuid = show
        item.grandparentTitle = show
        item.lastViewedAt = viewed
        return item
    }

    func test_newestFirstAcrossServers() {
        let main = [movie("plex://movie/a", viewed: 100), movie("plex://movie/b", viewed: 50)]
        let other = [movie("plex://movie/c", viewed: 80)]
        let picks = PlexDataStore.mergeContinueWatching([main, other])
        XCTAssertEqual(picks.map(\.list), [0, 1, 0])
        XCTAssertEqual(picks.map(\.index), [0, 0, 1])
    }

    func test_oneCardPerShow_theMostRecentlyWatchedServer() {
        // Next up on the main server, an older episode in progress on another server.
        let main = [episode(show: "plex://show/series", viewed: 200)]
        let other = [episode(show: "plex://show/series", viewed: 100)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, other]).map(\.list), [0])
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([other, main]).map(\.list), [1])
    }

    func test_twoLibrariesOnOneServer_areOneCard() {
        let main = [movie("plex://movie/a", viewed: 100, key: "4k"), movie("plex://movie/a", viewed: 100, key: "hd")]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main]).count, 1)
    }

    func test_aTieKeepsTheSignedInServersCopy() {
        let main = [movie("plex://movie/a", viewed: 100)]
        let other = [movie("plex://movie/a", viewed: 100)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, other]).map(\.list), [0])
    }

    /// An unmatched file's local guid means nothing on another server.
    func test_localGuidsNeverMerge() {
        let main = [movie("local://410", viewed: 100)]
        let other = [movie("local://410", viewed: 90)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, other]).count, 2)
    }

    private func copy(_ guid: String, resolution: String, viewed: Int, offset: Int, key: String) -> PlexMetadata {
        var item = movie(guid, viewed: viewed, key: key)
        item.viewOffset = offset
        item.Media = [PlexMedia(id: 1, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
                                audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: resolution,
                                container: nil, videoFrameRate: nil, Part: nil)]
        return item
    }

    /// A 4K and a 1080p copy (two libraries of one server) are two cards, next
    /// to each other even with another title watched in between.
    func test_copiesOfDifferentQuality_areSeparateCardsSideBySide() {
        let main = [
            copy("plex://movie/jw", resolution: "4k", viewed: 300, offset: 60_000, key: "4k"),
            movie("plex://movie/other", viewed: 200, key: "o"),
            copy("plex://movie/jw", resolution: "1080", viewed: 100, offset: 10_000, key: "hd")
        ]
        let picks = PlexDataStore.mergeContinueWatching([main])
        XCTAssertEqual(picks.map(\.index), [0, 2, 1])
    }

    /// The same quality on two servers is one card, the more recently watched.
    func test_sameQualityOnTwoServers_mergesToTheNewer() {
        let main = [copy("plex://movie/jw", resolution: "1080", viewed: 100, offset: 1, key: "a")]
        let other = [copy("plex://movie/jw", resolution: "1080", viewed: 200, offset: 2, key: "b"),
                     copy("plex://movie/jw", resolution: "2160", viewed: 50, offset: 3, key: "c")]
        let picks = PlexDataStore.mergeContinueWatching([main, other])
        XCTAssertEqual(picks.map { "\($0.list):\($0.index)" }, ["1:0", "1:1"])
    }

    /// Both cards show the most recently watched copy's position.
    func test_copiesShareTheNewestResumePoint() {
        let metas = [copy("plex://movie/jw", resolution: "4k", viewed: 100, offset: 10_000, key: "4k"),
                     copy("plex://movie/jw", resolution: "1080", viewed: 300, offset: 90_000, key: "hd")]
        let shared = PlexDataStore.sharingResumePoints(metas)
        XCTAssertEqual(shared.map(\.viewOffset), [90_000, 90_000])
        XCTAssertEqual(shared.map(\.lastViewedAt), [300, 300])
    }

    /// Different episodes of a show never share a position.
    func test_differentEpisodesKeepTheirOwnPoint() {
        var first = episode(show: "plex://show/s", viewed: 100)
        first.guid = "plex://episode/1"; first.viewOffset = 5
        var second = episode(show: "plex://show/s", viewed: 200)
        second.guid = "plex://episode/2"; second.viewOffset = 9
        XCTAssertEqual(PlexDataStore.sharingResumePoints([first, second]).map(\.viewOffset), [5, 9])
    }

    // MARK: - Setups other than several owned servers

    private func versions(_ guid: String, _ resolutions: [String], viewed: Int, key: String) -> PlexMetadata {
        var item = movie(guid, viewed: viewed, key: key)
        item.Media = resolutions.enumerated().map { index, resolution in
            PlexMedia(id: index, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
                      audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: resolution,
                      container: nil, videoFrameRate: nil, Part: nil)
        }
        return item
    }

    /// One server: its own hub, newest first, nothing dropped.
    func test_singleServer_keepsEveryItemNewestFirst() {
        let main = [movie("plex://movie/a", viewed: 10, key: "1"),
                    movie("plex://movie/b", viewed: 30, key: "2"),
                    episode(show: "plex://show/s", viewed: 20, key: "3")]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main]).map(\.index), [1, 2, 0])
    }

    /// Only shared servers, or a signed-in server with nothing in progress:
    /// the other lists still make the row.
    func test_emptySignedInList_othersStillMerge() {
        let shared = [movie("plex://movie/a", viewed: 50)]
        let second = [movie("plex://movie/a", viewed: 90), movie("plex://movie/b", viewed: 10)]
        let picks = PlexDataStore.mergeContinueWatching([[], shared, second])
        XCTAssertEqual(picks.map { "\($0.list):\($0.index)" }, ["2:0", "2:1"])
    }

    /// An unreachable server brings no list (or an empty one): the rest are untouched.
    func test_unreachableServer_isJustAbsent() {
        let main = [movie("plex://movie/a", viewed: 50), movie("plex://movie/b", viewed: 40)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, []]).map(\.index), [0, 1])
    }

    /// 4K and 1080p stored as versions of one item: one card, at its best quality.
    func test_versionsOfOneItem_areOneCard() {
        let item = versions("plex://movie/jw", ["1080", "4k"], viewed: 100, key: "1")
        XCTAssertEqual(PlexDataStore.qualityKey(item), "4k")
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([[item]]).count, 1)
    }

    /// Versions on one server beside a separate 1080p copy on another: the
    /// 1080p copy is its own card, and both resume from the newer position.
    func test_versionsBesideASeparateCopy() {
        var combined = versions("plex://movie/jw", ["4k", "1080"], viewed: 100, key: "1")
        combined.viewOffset = 10
        var separate = copy("plex://movie/jw", resolution: "1080", viewed: 200, offset: 99, key: "9")
        separate.viewOffset = 99
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([[combined], [separate]]).count, 2)
        XCTAssertEqual(PlexDataStore.sharingResumePoints([combined, separate]).map(\.viewOffset), [99, 99])
    }

    /// Two different shows with one title and no Plex guid (a legacy agent)
    /// never merge, on one server or across two.
    func test_showsWithoutAGuid_neverMergeByTitle() {
        func legacy(_ show: String, viewed: Int) -> PlexMetadata {
            var item = PlexMetadata(ratingKey: "e\(show)", type: "episode", title: "Episode")
            item.grandparentTitle = "The Office"
            item.grandparentRatingKey = show
            item.lastViewedAt = viewed
            return item
        }
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([[legacy("uk", viewed: 2), legacy("us", viewed: 1)]]).count, 2)
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([[legacy("uk", viewed: 2)], [legacy("uk", viewed: 1)]]).count, 2)
    }
}

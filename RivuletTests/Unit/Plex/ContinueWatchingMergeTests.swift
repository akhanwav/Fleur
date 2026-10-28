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
        let alpha = [movie("plex://movie/c", viewed: 80)]
        let picks = PlexDataStore.mergeContinueWatching([main, alpha])
        XCTAssertEqual(picks.map(\.list), [0, 1, 0])
        XCTAssertEqual(picks.map(\.index), [0, 0, 1])
    }

    func test_oneCardPerShow_theMostRecentlyWatchedServer() {
        // Next up on the main server, an older episode in progress on Alpha.
        let main = [episode(show: "plex://show/yaga", viewed: 200)]
        let alpha = [episode(show: "plex://show/yaga", viewed: 100)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, alpha]).map(\.list), [0])
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([alpha, main]).map(\.list), [1])
    }

    func test_twoLibrariesOnOneServer_areOneCard() {
        let main = [movie("plex://movie/a", viewed: 100, key: "4k"), movie("plex://movie/a", viewed: 100, key: "hd")]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main]).count, 1)
    }

    func test_aTieKeepsTheSignedInServersCopy() {
        let main = [movie("plex://movie/a", viewed: 100)]
        let alpha = [movie("plex://movie/a", viewed: 100)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, alpha]).map(\.list), [0])
    }

    /// An unmatched file's local guid means nothing on another server.
    func test_localGuidsNeverMerge() {
        let main = [movie("local://410", viewed: 100)]
        let alpha = [movie("local://410", viewed: 90)]
        XCTAssertEqual(PlexDataStore.mergeContinueWatching([main, alpha]).count, 2)
    }
}

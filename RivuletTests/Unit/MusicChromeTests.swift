// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class MusicChromeTests: XCTestCase {

    // Apple Music rounds a duration: 205.667s reads 3:26, not 3:25.
    func test_clock_rounds() {
        XCTAssertEqual(MusicChrome.clock(205.667), "3:26")
        XCTAssertEqual(MusicChrome.clock(59.5), "1:00")
        XCTAssertEqual(MusicChrome.clock(3727), "1:02:07")
    }

    // A lyric's timestamp under a minute keeps its minutes digit.
    func test_clock_padsSecondsUnderAMinute() {
        XCTAssertEqual(MusicChrome.clock(9), "0:09")
        XCTAssertEqual(MusicChrome.clock(69), "1:09")
    }

    func test_titleOverflow_onlyWhenTheTitleWraps() {
        XCTAssertEqual(MusicHeaderCell.titleOverflow("Vice Re-Verses", width: 880), 0)
        XCTAssertEqual(
            MusicHeaderCell.titleOverflow("Spider-Man: Into the Spider-Verse (Original Score)", width: 880), 68)
    }

    // The lyrics countdown lights one bullet for each third of the wait.
    func test_countdown_bullets_fill_left_to_right() {
        let alphas = { MusicLyricsPaneView.countdownAlphas(elapsed: $0, start: $1, dim: 0.175) }
        XCTAssertEqual(alphas(0, 9), [0.175, 0.175, 0.175])
        XCTAssertEqual(alphas(3, 9), [1, 0.175, 0.175])
        XCTAssertEqual(alphas(4.5, 9)[1], 0.5875, accuracy: 0.0001)
        XCTAssertEqual(alphas(9, 9), [1, 1, 1])
        // A first line inside two seconds has no wait to count.
        XCTAssertEqual(alphas(0, 1.5), [1, 1, 1])
    }

    // Apple's footer: nearest minute, no comma between the units, the count alone without a length.
    func test_songSummary() {
        XCTAssertEqual(MusicChrome.songSummary(count: 12, duration: 48 * 60 + 29), "12 songs, 48 minutes")
        XCTAssertEqual(MusicChrome.songSummary(count: 12, duration: 48 * 60 + 30), "12 songs, 49 minutes")
        XCTAssertEqual(MusicChrome.songSummary(count: 772, duration: 45 * 3600 + 36 * 60), "772 songs, 45 hours 36 minutes")
        XCTAssertEqual(MusicChrome.songSummary(count: 1, duration: 60), "1 song, 1 minute")
        XCTAssertEqual(MusicChrome.songSummary(count: 9, duration: nil), "9 Songs")
        XCTAssertEqual(MusicChrome.songSummary(count: 1, duration: 20), "1 Song")
        XCTAssertEqual(MusicChrome.songSummary(count: 0, duration: 600), "")
    }

    private func makeTrack(_ id: String, disc: Int? = nil) -> MusicTrack {
        let ref = { MediaItemRef(providerID: "plex:x", itemID: $0) }
        return MusicTrack(ref: ref(id), title: "T", albumRef: ref("album"), albumTitle: nil,
                          artistRef: ref("artist"), artistName: nil,
                          trackNumber: nil, discNumber: disc, duration: 240,
                          audioCodec: nil, bitrate: nil, sampleRate: nil,
                          artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                          userState: .empty)
    }

    // Apple's rank order: go-to rows, then the queue rows, then Favorite. No "Go to Album" on the album's own page.
    func test_trackMenu_order() {
        // The playlist row appears only once a signed-in host has loaded playlists.
        let titles = { MusicMenus.track(self.makeTrack("1"), screen: $0) { _ in }.map(\.title)
            .filter { !$0.hasPrefix("Add to a Playlist") } }
        XCTAssertEqual(titles(.songs), ["Go to Artist", "Go to Album", "Play Next", "Play After", "Favorite"])
        XCTAssertEqual(titles(.album), ["Go to Artist", "Play Next", "Play After", "Favorite"])
    }

    // Disc headings need a disc number on every track and at least two runs.
    func test_discRuns() {
        func runs(_ discs: [Int?]) -> [String] {
            let tracks = discs.enumerated().map { makeTrack("\($0)", disc: $1) }
            return MusicAlbumViewController.discRuns(in: tracks).map { "\($0.disc):\($0.tracks)" }
        }
        XCTAssertEqual(runs([1, 1, 2, 2, 2]), ["1:0..<2", "2:2..<5"])
        XCTAssertEqual(runs([1, 1, 1]), [])
        XCTAssertEqual(runs([1, nil, 2]), [])
        XCTAssertEqual(runs([]), [])
    }
}

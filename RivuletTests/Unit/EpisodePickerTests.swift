// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class EpisodePickerTests: XCTestCase {

    // MARK: - Builders

    private func episode(
        _ id: String,
        season: Int? = 1,
        number: Int?,
        played: Bool = false,
        offset: TimeInterval = 0
    ) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: id),
            kind: .episode,
            title: "Episode \(number.map(String.init) ?? "?")",
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: 1800,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: number,
            seasonNumber: season,
            childProgress: nil,
            userState: MediaUserState(
                isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil
            ),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    // MARK: - firstUnplayed

    func testEmptySeasonReturnsNil() {
        XCTAssertNil(EpisodePicker.firstUnplayed(in: []))
    }

    func testFreshSeasonStartsAtEpisodeOne() {
        let eps = [episode("e1", number: 1), episode("e2", number: 2)]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e1")
    }

    func testSkipsWatchedEpisodesToFirstUnplayed() {
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
            episode("e3", number: 3),
            episode("e4", number: 4),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e3")
    }

    func testInProgressEpisodeWinsOverLaterUnplayed() {
        // e1 watched, e2 started but unfinished, e3 untouched → resume e2.
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, offset: 300),
            episode("e3", number: 3),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testFullyWatchedSeasonRestartsAtEpisodeOne() {
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e1")
    }

    func testPlayedEpisodeWithResumeOffsetIsNotTreatedAsInProgress() {
        // A rewatch leaves viewCount > 0 AND a viewOffset. The next NEW episode
        // should still win over resuming a finished one.
        let eps = [
            episode("e1", number: 1, played: true, offset: 120),
            episode("e2", number: 2),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testUnorderedInputIsSortedBeforePicking() {
        let eps = [
            episode("e3", number: 3),
            episode("e1", number: 1, played: true),
            episode("e2", number: 2),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testSortsAcrossSeasonsBeforeEpisodes() {
        let eps = [
            episode("s2e1", season: 2, number: 1),
            episode("s1e2", season: 1, number: 2),
            episode("s1e1", season: 1, number: 1, played: true),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "s1e2")
    }

    func testMissingEpisodeNumbersFallBackToServerOrder() {
        let eps = [
            episode("first", season: nil, number: nil, played: true),
            episode("second", season: nil, number: nil),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "second")
    }

    // MARK: - nextUp

    func testNextUpIsTheEpisodeInProgress() {
        XCTAssertEqual(EpisodePicker.nextUpIndex(inProgress: [false, true, false], played: [true, false, false]), 1)
    }

    func testNextUpFollowsTheLastPlayedEpisode() {
        // Watched through E3 (E1 skipped): next up is E4, not E1.
        XCTAssertEqual(
            EpisodePicker.nextUpIndex(inProgress: [false, false, false, false], played: [false, true, true, false]), 3)
    }

    func testNextUpAfterTheLastPlayedFallsBackToTheFirstUnplayed() {
        XCTAssertEqual(EpisodePicker.nextUpIndex(inProgress: [false, false, false], played: [false, true, true]), 0)
    }

    func testNextUpOfAFullyWatchedShowIsTheFirst() {
        XCTAssertEqual(EpisodePicker.nextUpIndex(inProgress: [false, false], played: [true, true]), 0)
        XCTAssertNil(EpisodePicker.nextUpIndex(inProgress: [], played: []))
    }

    func testNextUpOrdersEpisodesFirst() {
        let eps = [
            episode("s2e1", season: 2, number: 1),
            episode("s1e2", season: 1, number: 2, played: true),
            episode("s1e1", season: 1, number: 1, played: true),
        ]
        XCTAssertEqual(EpisodePicker.nextUp(in: eps)?.ref.itemID, "s2e1")
    }

    // MARK: - playTitle

    func testNamesTheEpisodePlayWillStart() {
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e3", season: 1, number: 3)), "Play S1 · E3")
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("s5e3", season: 5, number: 3)), "Play S5 · E3")
    }

    func testResumesAnInProgressEpisode() {
        let ep = episode("e5", season: 2, number: 5, offset: 300)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep), "Resume S2 · E5 · 25 min left")
    }

    func testFullyWatchedEpisodePlaysAgain() {
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e1", number: 1, played: true)), "Play Again")
    }

    func testWithoutNumberingFallsBackToPlainWording() {
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e1", season: nil, number: nil)), "Play")
        let started = episode("e1", season: nil, number: nil, offset: 300)
        XCTAssertEqual(EpisodePicker.playTitle(for: started), "Resume · 25 min left")
    }

    /// A resume point outranks the watched flag (a rewatch in progress).
    func testRewatchInProgressResumes() {
        let ep = episode("e3", number: 3, played: true, offset: 300)
        XCTAssertEqual(EpisodePicker.playTitle(for: ep), "Resume S1 · E3 · 25 min left")
    }

    /// Past the policy's completion ceiling there is nothing worth resuming.
    func testNearlyFinishedItemDoesNotResume() {
        XCTAssertEqual(EpisodePicker.playTitle(for: episode("e3", number: 3, offset: 1780)), "Play S1 · E3")
    }

    /// A show before its episode resolves: no runtime, no numbering.
    func testUnresolvedShowSaysPlay() {
        XCTAssertEqual(EpisodePicker.playTitle(resumes: false, watched: false), "Play")
        XCTAssertEqual(EpisodePicker.playTitle(resumes: false, watched: true), "Play Again")
        // A resume with no runtime to measure against keeps the plain wording.
        XCTAssertEqual(EpisodePicker.playTitle(resumes: true, watched: false), "Resume")
    }

    // MARK: - isInProgress

    func testIsInProgressSemantics() {
        let untouched = MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        let started = MediaUserState(isPlayed: false, viewOffset: 60, isFavorite: false, lastViewedAt: nil)
        let finished = MediaUserState(isPlayed: true, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        let rewatching = MediaUserState(isPlayed: true, viewOffset: 60, isFavorite: false, lastViewedAt: nil)

        XCTAssertFalse(untouched.isInProgress)
        XCTAssertTrue(started.isInProgress)
        XCTAssertFalse(finished.isInProgress)
        XCTAssertFalse(rewatching.isInProgress)
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class ResumeTextTests: XCTestCase {

    func test_timeLeft_minutesAndHours() {
        XCTAssertEqual(ResumeText.timeLeft(offsetSeconds: 600, runtimeSeconds: 3120), "42 min left")
        XCTAssertEqual(ResumeText.timeLeft(offsetSeconds: 600, runtimeSeconds: 600 + 72 * 60), "1 hr 12 min left")
        XCTAssertEqual(ResumeText.timeLeft(offsetSeconds: 600, runtimeSeconds: 600 + 120 * 60), "2 hr left")
    }

    func test_timeLeft_roundsUp() {
        XCTAssertEqual(ResumeText.timeLeft(offsetSeconds: 600, runtimeSeconds: 600 + 41 * 60 + 5), "42 min left")
    }

    func test_timeLeft_nilWithoutAResumePoint() {
        XCTAssertNil(ResumeText.timeLeft(offsetSeconds: 0, runtimeSeconds: 3600))
        XCTAssertNil(ResumeText.timeLeft(offsetSeconds: 3500, runtimeSeconds: 3600), "past the completion ceiling")
        XCTAssertNil(ResumeText.timeLeft(offsetSeconds: 600, runtimeSeconds: nil))
    }

    func test_line() {
        XCTAssertEqual(ResumeText.line(season: 2, episode: 5, offsetSeconds: 300, runtimeSeconds: 1680),
                       "S2 · E5 · 23 min left")
        XCTAssertEqual(ResumeText.line(season: nil, episode: nil, offsetSeconds: 600, runtimeSeconds: 3120),
                       "42 min left")
        XCTAssertEqual(ResumeText.line(season: 2, episode: 5, offsetSeconds: 0, runtimeSeconds: 1680), "S2 · E5")
        XCTAssertNil(ResumeText.line(season: nil, episode: nil, offsetSeconds: 0, runtimeSeconds: 3120))
    }

    func test_continueWatchingCaption() {
        let movie = PosterCaptionView.continueWatchingText(
            title: "Superman", year: 2025, show: nil, season: nil, episode: nil,
            offsetSeconds: 600, runtimeSeconds: 3120)
        XCTAssertEqual(movie.title, "Superman")
        XCTAssertEqual(movie.detail, "42 min left")
        let episode = PosterCaptionView.continueWatchingText(
            title: "Pilot", year: nil, show: "Silo", season: 2, episode: 5,
            offsetSeconds: 300, runtimeSeconds: 1680)
        XCTAssertEqual(episode.title, "Silo")
        XCTAssertEqual(episode.detail, "S2 · E5 · 23 min left")
        let unstarted = PosterCaptionView.continueWatchingText(
            title: "Superman", year: 2025, show: nil, season: nil, episode: nil,
            offsetSeconds: 0, runtimeSeconds: 3120)
        XCTAssertEqual(unstarted.detail, "2025")
    }
}

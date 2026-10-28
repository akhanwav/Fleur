// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Which episodes take a TMDB description, and when TMDB's numbering is
/// trusted. The network half is exercised on device.
final class EpisodeSummaryFillTests: XCTestCase {

    private func episode(summary: String?, season: Int? = 1, number: Int? = 3,
                         type: String = "episode") -> PlexMetadata {
        var item = PlexMetadata(ratingKey: "1", type: type, title: "Episode")
        item.summary = summary
        item.parentIndex = season
        item.index = number
        return item
    }

    func test_onlyAnEmptyEpisodeSummaryIsFilled() {
        XCTAssertTrue(EpisodeSummaryFill.needsSummary(episode(summary: nil)))
        XCTAssertTrue(EpisodeSummaryFill.needsSummary(episode(summary: "  ")))
        XCTAssertFalse(EpisodeSummaryFill.needsSummary(episode(summary: "The server's own text.")))
        XCTAssertFalse(EpisodeSummaryFill.needsSummary(episode(summary: nil, type: "movie")))
    }

    func test_yearNumberedSeasonsAreLeftAlone() {
        XCTAssertFalse(EpisodeSummaryFill.needsSummary(episode(summary: nil, season: 2026, number: 99)))
        XCTAssertFalse(EpisodeSummaryFill.needsSummary(episode(summary: nil, season: nil)))
        XCTAssertFalse(EpisodeSummaryFill.needsSummary(episode(summary: nil, number: nil)))
    }

    func test_airYearsMoreThanAYearApartAreNotTheSameEpisode() {
        XCTAssertTrue(EpisodeSummaryFill.yearsAgree("2020-10-11", "2020-10-11"))
        XCTAssertTrue(EpisodeSummaryFill.yearsAgree("2021-01-02", "2020-12-31"))
        XCTAssertTrue(EpisodeSummaryFill.yearsAgree(nil, "2020-10-11"))
        XCTAssertFalse(EpisodeSummaryFill.yearsAgree("2024-03-01", "1998-03-01"))
    }
}

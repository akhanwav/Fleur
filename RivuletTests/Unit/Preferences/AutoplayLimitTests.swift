// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class AutoplayLimitTests: XCTestCase {
    func test_off_neverStopsAutoplay() {
        XCTAssertTrue(AutoplayLimit.off.allowsAutoplay(afterEpisodesInARow: 1))
        XCTAssertTrue(AutoplayLimit.off.allowsAutoplay(afterEpisodesInARow: 50))
    }

    /// Three Episodes: the first plays from the remote, two more by autoplay, then Up Next waits.
    func test_three_stopsAfterTheThirdEpisode() {
        XCTAssertTrue(AutoplayLimit.three.allowsAutoplay(afterEpisodesInARow: 1))
        XCTAssertTrue(AutoplayLimit.three.allowsAutoplay(afterEpisodesInARow: 2))
        XCTAssertFalse(AutoplayLimit.three.allowsAutoplay(afterEpisodesInARow: 3))
    }
}

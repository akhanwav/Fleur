// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PhotoViewerIndexTests: XCTestCase {
    private func step(_ from: Int, _ by: Int, count: Int, wraps: Bool = false, clips: Set<Int> = []) -> Int? {
        PhotoViewerIndex.step(from: from, by: by, count: count, wraps: wraps, skipping: clips.contains)
    }

    func test_stepsOne_andStopsAtBothEnds() {
        XCTAssertEqual(step(1, 1, count: 3), 2)
        XCTAssertEqual(step(1, -1, count: 3), 0)
        XCTAssertNil(step(2, 1, count: 3))
        XCTAssertNil(step(0, -1, count: 3))
    }

    func test_wrapsOnlyWhenAsked() {
        XCTAssertEqual(step(2, 1, count: 3, wraps: true), 0)
        XCTAssertEqual(step(0, -1, count: 3, wraps: true), 2)
    }

    func test_skipsClips() {
        XCTAssertEqual(step(0, 1, count: 4, clips: [1, 2]), 3)
        XCTAssertNil(step(0, 1, count: 3, clips: [1, 2]), "only clips ahead and no wrap")
        XCTAssertEqual(step(2, 1, count: 4, wraps: true, clips: [3, 0]), 1)
    }

    func test_nowhereToGo() {
        XCTAssertNil(step(0, 1, count: 0))
        XCTAssertNil(step(0, 1, count: 1, wraps: true), "one photo does not step onto itself")
        XCTAssertNil(step(0, 1, count: 3, wraps: true, clips: [1, 2]), "every other item is a clip")
        XCTAssertNil(step(0, 0, count: 3))
    }
}

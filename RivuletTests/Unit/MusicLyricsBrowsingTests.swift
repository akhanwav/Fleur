// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class MusicLyricsBrowsingTests: XCTestCase {

    // One-, two-, three- and one-row lyrics, 100pt apart, centred as the pane centres them.
    private let column = MusicLyricsColumn(tops: [0, 191, 473, 846], heights: [91, 182, 273, 91], centre: 429.5)
    private let empty = MusicLyricsColumn(tops: [], heights: [], centre: 429.5)

    private func after(_ events: (inout MusicLyricsBrowse) -> Void) -> MusicLyricsBrowse {
        var browse = MusicLyricsBrowse()
        events(&browse)
        return browse
    }

    // MARK: Column

    func test_offsetCentring_roundTripsThroughNearestLine_forMixedHeights() {
        XCTAssertEqual(column.tops.indices.map(column.offset(centring:)), [384, 148, -180, -462])
        for line in column.tops.indices {
            XCTAssertEqual(column.nearestLine(at: column.offset(centring: line)), line)
        }
    }

    func test_offsetCentring_isAWholePoint() {
        for line in column.tops.indices {
            let offset = column.offset(centring: line)
            XCTAssertEqual(offset, offset.rounded())
        }
    }

    func test_nearestLine_onATie_picksTheEarlierLine() {
        XCTAssertEqual(column.nearestLine(at: 266), 0)
    }

    func test_nearestLine_pastEitherEnd_picksTheEndLine() {
        XCTAssertEqual(column.nearestLine(at: 5000), 0)
        XCTAssertEqual(column.nearestLine(at: -5000), 3)
    }

    func test_nearestLine_emptyColumn_isNil() {
        XCTAssertNil(empty.nearestLine(at: 0))
    }

    func test_clamped_allows600PastEachEnd_andNoMore() {
        XCTAssertEqual(column.clamped(984), 984)
        XCTAssertEqual(column.clamped(985), 984)
        XCTAssertEqual(column.clamped(-1062), -1062)
        XCTAssertEqual(column.clamped(-1063), -1062)
    }

    func test_clamped_leavesAnInsideOffsetAlone() {
        XCTAssertEqual(column.clamped(12.5), 12.5)
        XCTAssertEqual(empty.clamped(12.5), 12.5)
    }

    func test_rest_zeroVelocity_isTheOffset() {
        XCTAssertEqual(MusicLyricsColumn.rest(from: 148, velocity: 0), 148)
    }

    func test_rest_2000PointsPerSecond_adds198() {
        XCTAssertEqual(MusicLyricsColumn.rest(from: 148, velocity: 2000), 346, accuracy: 0.001)
        XCTAssertEqual(MusicLyricsColumn.rest(from: 148, velocity: -2000), -50, accuracy: 0.001)
    }

    func test_pillShows_under40Only_bothSigns() {
        XCTAssertTrue(MusicLyricsColumn.pillShows(distance: 39.9))
        XCTAssertFalse(MusicLyricsColumn.pillShows(distance: 40))
        XCTAssertTrue(MusicLyricsColumn.pillShows(distance: -39.9))
        XCTAssertFalse(MusicLyricsColumn.pillShows(distance: -40))
    }

    func test_seekTime_staysOneSecondInsideTheDuration() {
        XCTAssertEqual(MusicLyricsColumn.seekTime(50, duration: 180), 50)
        XCTAssertEqual(MusicLyricsColumn.seekTime(179.6, duration: 180), 179)
        XCTAssertEqual(MusicLyricsColumn.seekTime(200, duration: 180), 179)
    }

    func test_seekTime_unknownDuration_passesTheStartThrough() {
        XCTAssertEqual(MusicLyricsColumn.seekTime(50, duration: 0), 50)
    }

    func test_seekTime_isNeverNegative() {
        XCTAssertEqual(MusicLyricsColumn.seekTime(-3, duration: 180), 0)
        XCTAssertEqual(MusicLyricsColumn.seekTime(-3, duration: 0), 0)
    }

    // MARK: Reducer

    func test_step_fromFollowing_selectsTheLineBesideTheSungOne() {
        var down = MusicLyricsBrowse()
        XCTAssertEqual(down.step(1, sung: 4, count: 10), .snap(5))
        XCTAssertEqual(down.phase, .selected(5))
        var up = MusicLyricsBrowse()
        XCTAssertEqual(up.step(-1, sung: 4, count: 10), .snap(3))
        XCTAssertEqual(up.phase, .selected(3))
    }

    func test_step_beforeTheFirstLine_selectsLineZero_eitherDirection() {
        var down = MusicLyricsBrowse()
        XCTAssertEqual(down.step(1, sung: nil, count: 10), .snap(0))
        var up = MusicLyricsBrowse()
        XCTAssertEqual(up.step(-1, sung: nil, count: 10), .snap(0))
    }

    func test_step_fromFollowingOnTheLastLine_down_selectsTheLastLine() {
        var browse = MusicLyricsBrowse()
        XCTAssertEqual(browse.step(1, sung: 9, count: 10), .snap(9))
        XCTAssertEqual(browse.phase, .selected(9))
    }

    func test_step_fromSelected_movesOneLine() {
        var browse = after { _ = $0.step(1, sung: 4, count: 10) }
        XCTAssertEqual(browse.step(1, sung: 4, count: 10), .snap(6))
        XCTAssertEqual(browse.step(-1, sung: 8, count: 10), .snap(5))
        XCTAssertEqual(browse.phase, .selected(5))
    }

    func test_step_atEitherEnd_returnsNone_andKeepsThePhase() {
        var first = after { _ = $0.step(-1, sung: 1, count: 10) }
        XCTAssertEqual(first.step(-1, sung: 1, count: 10), .none)
        XCTAssertEqual(first.phase, .selected(0))
        var last = after { _ = $0.step(1, sung: 8, count: 10) }
        XCTAssertEqual(last.step(1, sung: 8, count: 10), .none)
        XCTAssertEqual(last.phase, .selected(9))
    }

    func test_step_midDrag_startsFromTheLineTheDragBeganOn() {
        var browse = after { $0.dragBegan(nearest: 4) }
        XCTAssertEqual(browse.step(1, sung: 0, count: 10), .snap(5))
        XCTAssertEqual(browse.phase, .selected(5))
    }

    func test_step_emptyColumn_returnsNone() {
        var browse = MusicLyricsBrowse()
        XCTAssertEqual(browse.step(1, sung: nil, count: 0), .none)
        XCTAssertEqual(browse.phase, .following)
    }

    func test_dragBegan_fromFollowing_namesNoLine() {
        let browse = after { $0.dragBegan(nearest: 4) }
        XCTAssertEqual(browse.phase, .dragging(from: 4, named: false))
        XCTAssertNil(browse.namedLine)
    }

    func test_dragBegan_fromSelected_keepsItsLineNamed() {
        let browse = after {
            _ = $0.step(1, sung: 4, count: 10)
            $0.dragBegan(nearest: 7)
        }
        XCTAssertEqual(browse.phase, .dragging(from: 5, named: true))
        XCTAssertEqual(browse.namedLine, 5)
    }

    func test_dragBegan_whileDragging_keepsTheFirstLine() {
        let browse = after {
            $0.dragBegan(nearest: 4)
            $0.dragBegan(nearest: 7)
        }
        XCTAssertEqual(browse.phase, .dragging(from: 4, named: false))
    }

    func test_dragEnded_selectsTheNearestLine() {
        var browse = after { $0.dragBegan(nearest: 4) }
        XCTAssertEqual(browse.dragEnded(nearest: 7), .snap(7))
        XCTAssertEqual(browse.phase, .selected(7))
    }

    func test_dragEnded_afterAStepTookTheColumn_returnsNone() {
        var browse = after {
            $0.dragBegan(nearest: 4)
            _ = $0.step(1, sung: 0, count: 10)
        }
        XCTAssertEqual(browse.dragEnded(nearest: 8), .none)
        XCTAssertEqual(browse.phase, .selected(5))
    }

    func test_dragEnded_whileFollowing_returnsNone() {
        var browse = MusicLyricsBrowse()
        XCTAssertEqual(browse.dragEnded(nearest: 3), .none)
        XCTAssertEqual(browse.phase, .following)
    }

    func test_select_whileFollowing_isNotConsumed() {
        var browse = MusicLyricsBrowse()
        XCTAssertEqual(browse.select(nearest: 3, pillUp: false), .none)
        XCTAssertEqual(browse.phase, .following)
    }

    func test_select_onASelectedLine_seeksIt_evenBeforeThePillIsUp() {
        var browse = after { _ = $0.step(1, sung: 4, count: 10) }
        XCTAssertEqual(browse.select(nearest: 4, pillUp: false), .seek(5))
        XCTAssertEqual(browse.phase, .following)
    }

    func test_select_midDrag_withThePillUp_seeksTheNamedLine() {
        var browse = after {
            _ = $0.step(1, sung: 4, count: 10)
            $0.dragBegan(nearest: 5)
        }
        XCTAssertEqual(browse.select(nearest: 5, pillUp: true), .seek(5))
        XCTAssertEqual(browse.phase, .following)
    }

    func test_select_midDrag_pastThePill_restsOnTheNearestLine_andDoesNotSeek() {
        var browse = after {
            _ = $0.step(1, sung: 4, count: 10)
            $0.dragBegan(nearest: 5)
        }
        XCTAssertEqual(browse.select(nearest: 8, pillUp: false), .snap(8))
        XCTAssertEqual(browse.phase, .selected(8))
    }

    func test_select_midDragFromFollowing_neverSeeks() {
        var browse = after { $0.dragBegan(nearest: 4) }
        XCTAssertEqual(browse.select(nearest: 4, pillUp: true), .snap(4))
        XCTAssertEqual(browse.phase, .selected(4))
    }

    func test_cancel_whileSelected_andWhileDragging_follows() {
        var selected = after { _ = $0.step(1, sung: 4, count: 10) }
        XCTAssertEqual(selected.cancel(), .follow)
        XCTAssertEqual(selected.phase, .following)
        var dragging = after { $0.dragBegan(nearest: 4) }
        XCTAssertEqual(dragging.cancel(), .follow)
        XCTAssertEqual(dragging.phase, .following)
    }

    func test_cancel_whileFollowing_returnsNone() {
        var browse = MusicLyricsBrowse()
        XCTAssertEqual(browse.cancel(), .none)
    }

    func test_timeout_onASelectedLine_follows() {
        var browse = after { _ = $0.step(1, sung: 4, count: 10) }
        XCTAssertEqual(browse.timeout(), .follow)
        XCTAssertEqual(browse.phase, .following)
    }

    func test_timeout_whileAFingerIsDown_isIgnored() {
        var browse = after { $0.dragBegan(nearest: 4) }
        XCTAssertEqual(browse.timeout(), .none)
        XCTAssertEqual(browse.phase, .dragging(from: 4, named: false))
    }

    func test_timeout_whileFollowing_returnsNone() {
        var browse = MusicLyricsBrowse()
        XCTAssertEqual(browse.timeout(), .none)
    }

    func test_namedLine_isTheSelectedOrNamedDragLine_only() {
        XCTAssertNil(MusicLyricsBrowse().namedLine)
        XCTAssertEqual(after { _ = $0.step(1, sung: 4, count: 10) }.namedLine, 5)
        XCTAssertNil(after { $0.dragBegan(nearest: 4) }.namedLine)
        XCTAssertFalse(MusicLyricsBrowse().isBrowsing)
        XCTAssertTrue(after { $0.dragBegan(nearest: 4) }.isBrowsing)
    }
}

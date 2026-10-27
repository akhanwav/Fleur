// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest
@testable import Rivulet

/// The Recently Searched row (#292).
///
/// `preferredFocusEnvironments` is the thing worth pinning: the cell is a
/// full-width container that must never hold focus itself, so it hands the
/// engine its cards instead. If that returns the wrong thing the row is either
/// unreachable or focus parks on an empty band, and neither shows up in a build.
final class SearchRecentsCellTests: XCTestCase {

    private func item(_ id: String, title: String, kind: MediaKind, year: Int?) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: id),
            kind: kind,
            title: title,
            sortTitle: nil,
            overview: nil,
            year: year,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(
                isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    @MainActor
    func test_configure_handsTheEngineOneCardPerRecent() {
        let cell = SearchRecentsCell(frame: CGRect(x: 0, y: 0, width: 1920, height: 300))
        cell.configure(recentItems: [
            item("1", title: "Alien", kind: .movie, year: 1979),
            item("2", title: "Severance", kind: .show, year: nil)
        ])
        cell.layoutIfNeeded()

        // Two cards, then Clear All.
        XCTAssertEqual(cell.preferredFocusEnvironments.count, 3)
        for card in cell.preferredFocusEnvironments {
            XCTAssertTrue(
                (card as? UIView)?.canBecomeFocused == true,
                "a recents card the engine cannot focus makes the row dead")
        }
    }

    /// Chosen behaviour, not an accident: the empty-query screen has no prompt,
    /// so with nothing to show the cell offers nothing to focus rather than
    /// parking focus on a blank full-width band.
    @MainActor
    func test_configure_withNoRecents_offersNothingToFocus() {
        let cell = SearchRecentsCell(frame: CGRect(x: 0, y: 0, width: 1920, height: 300))
        cell.configure(recentItems: [])
        cell.layoutIfNeeded()

        XCTAssertTrue(cell.preferredFocusEnvironments.isEmpty)
    }

    /// Rebuilt from scratch each configure. A stale card would reopen the wrong
    /// item, which is worse than not showing it.
    @MainActor
    func test_configure_replacesThePreviousCards() {
        let cell = SearchRecentsCell(frame: CGRect(x: 0, y: 0, width: 1920, height: 300))
        cell.configure(recentItems: [
            item("1", title: "Alien", kind: .movie, year: 1979),
            item("2", title: "Severance", kind: .show, year: nil)
        ])
        cell.configure(recentItems: [item("3", title: "Dune", kind: .movie, year: 2021)])
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.preferredFocusEnvironments.count, 2)
    }

    /// The grid beside the grid keyboard (884pt of page) shows all ten recents
    /// without scrolling.
    @MainActor
    func test_cardHeight_fitsFiveRowsInThePageBesideTheKeyboard() {
        let header: CGFloat = 39
        let height = SearchRecentsCell.cardHeight(fitting: 884, headerHeight: header)
        let used = 17 + header + 16 + height * 5 + 24 * 4 + 60
        XCTAssertLessThanOrEqual(used, 884)
        XCTAssertGreaterThan(height, 100)
    }

    /// Two columns of five: the oldest recents past ten are not drawn.
    @MainActor
    func test_configure_showsAtMostTenRecents() {
        let cell = SearchRecentsCell(frame: CGRect(x: 0, y: 0, width: 1330, height: 884))
        cell.configure(recentItems: (1...12).map {
            item("\($0)", title: "Title \($0)", kind: .movie, year: 2000)
        })
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.preferredFocusEnvironments.count, SearchRecentsCell.maxItems + 1)
        XCTAssertEqual(SearchRecentsCell.maxItems, 10)
    }

    /// Clear All is offered after the cards (Right from the keyboard enters at
    /// the first card) and only while there is something to clear.
    @MainActor
    func test_clearAll_followsTheCardsAndHidesWhenEmpty() {
        let cell = SearchRecentsCell(frame: CGRect(x: 0, y: 0, width: 1330, height: 884))
        cell.configure(recentItems: [item("1", title: "Alien", kind: .movie, year: 1979)])
        cell.layoutIfNeeded()

        let environments = cell.preferredFocusEnvironments
        XCTAssertEqual(environments.count, 2)
        XCTAssertFalse(SearchRecentsCell.isClearAllButton(environments.first as? UIView))
        XCTAssertTrue(SearchRecentsCell.isClearAllButton(environments.last as? UIView))

        cell.configure(recentItems: [])
        XCTAssertTrue((environments.last as? UIView)?.isHidden == true)
    }
}

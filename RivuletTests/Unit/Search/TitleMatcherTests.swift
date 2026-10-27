// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Search suggestions' title matching, with the queries Search is tuned for.
final class TitleMatcherTests: XCTestCase {

    private func match(_ title: String, _ query: String) -> TitleMatch? {
        TitleMatcher.match(TitleMatcher.Keys(title: title), SearchSuggestions.query(for: query))
    }

    func test_spacesPunctuationAndCase_doNotMatter() {
        XCTAssertEqual(match("The NeverEnding Story", "the never ending"), .prefix)
        XCTAssertEqual(match("The NeverEnding Story", "neverending"), .prefix)
        XCTAssertEqual(match("Spider-Man", "spider man"), .exact)
        XCTAssertEqual(match("Spider-Man: No Way Home", "spider man"), .prefix)
        XCTAssertEqual(match("WALL·E", "wall e"), .exact)
        XCTAssertEqual(match("Amélie", "amelie"), .exact)
        XCTAssertEqual(match("Never Ending", "the never ending"), .prefix)
    }

    func test_typos_matchTheStartOfTheTitle() {
        XCTAssertEqual(match("The Godfather", "godfathr"), .fuzzy)
        XCTAssertEqual(match("The NeverEnding Story", "neverendng"), .fuzzy)
        XCTAssertEqual(match("The NeverEnding Story", "the neverendnig"), .fuzzy)
        // Too short to guess at: one edit from too many words.
        XCTAssertNil(match("Gotham", "gotx"))
    }

    func test_initials() {
        XCTAssertEqual(match("Dragon Ball Z", "dbz"), .acronym)
        XCTAssertEqual(match("The Lord of the Rings: The Fellowship of the Ring", "lotr"), .acronym)
        XCTAssertEqual(match("Game of Thrones", "got"), .acronym)
        XCTAssertEqual(match("The Walking Dead", "twd"), .acronym)
        XCTAssertEqual(match("Law & Order: Special Victims Unit", "svu"), .acronym)
    }

    func test_nicknames() {
        XCTAssertEqual(match("The Last of Us", "tlou"), .acronym)
        XCTAssertEqual(match("American Horror Story", "ahs"), .acronym)
        XCTAssertEqual(match("It's Always Sunny in Philadelphia", "sunny"), .alias)
    }

    /// A short query is both a title start and initials: "got" offers Gotham
    /// and Game of Thrones side by side.
    func test_shortQuery_mixesPrefixAndInitials() {
        XCTAssertEqual(match("Gotham", "got")?.rank, match("Game of Thrones", "got")?.rank)
    }

    func test_tmdbQueries_coverWhatTMDBMisses() {
        let neverEnding = SearchSuggestions.tmdbQueries(for: "the never ending")
        XCTAssertEqual(neverEnding.first, "the never ending")
        XCTAssertTrue(neverEnding.contains("the neverending"))
        XCTAssertTrue(neverEnding.contains("never ending"))
        XCTAssertFalse(neverEnding.contains("thenever ending"))

        XCTAssertTrue(SearchSuggestions.tmdbQueries(for: "wall e").contains("wall·e"))
        XCTAssertTrue(SearchSuggestions.tmdbQueries(for: "godfathr").contains("godfat"))
        XCTAssertTrue(SearchSuggestions.tmdbQueries(for: "got").contains("Game of Thrones"))
        XCTAssertLessThanOrEqual(SearchSuggestions.tmdbQueries(for: "a b c d e f g").count,
                                 SearchSuggestions.maxQueries)
    }

    func test_rank_matchThenOwnedThenPopularity() {
        func suggestion(_ title: String, _ match: TitleMatch, owned: Bool, popularity: Double) -> SearchSuggestion {
            SearchSuggestion(key: title, title: title, year: nil, kind: .movie, match: match,
                             popularity: popularity,
                             owned: owned ? PlexMetadata(ratingKey: "1", title: title) : nil, tmdb: nil)
        }
        let ranked = SearchSuggestions.rank([
            suggestion("Popular prefix", .prefix, owned: false, popularity: 500),
            suggestion("Owned prefix", .prefix, owned: true, popularity: 1),
            suggestion("Exact", .exact, owned: false, popularity: 0),
            suggestion("Contains", .contains, owned: true, popularity: 900)
        ])
        // Exact and start-of-title are one kind: what you have, then what is popular.
        XCTAssertEqual(ranked.map(\.title), ["Owned prefix", "Popular prefix", "Exact", "Contains"])
    }

    func test_merge_keepsTheBetterMatchTheCopyAndThePopularity() {
        let library = SearchSuggestion(key: "movie:1", title: "The Godfather", year: 1972, kind: .movie,
                                       match: .fuzzy, popularity: 0,
                                       owned: PlexMetadata(ratingKey: "9", title: "The Godfather"), tmdb: nil)
        let remote = SearchSuggestion(key: "movie:1", title: "The Godfather", year: 1972, kind: .movie,
                                      match: .prefix, popularity: 53, owned: nil, tmdb: nil)
        let merged = SearchSuggestions.merge([library], [remote])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].match, .prefix)
        XCTAssertEqual(merged[0].popularity, 53)
        XCTAssertTrue(merged[0].isOwned)
    }
}

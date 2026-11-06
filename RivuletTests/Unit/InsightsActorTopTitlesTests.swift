import XCTest
@testable import Rivulet

/// The Insights actor row: the best-known titles by TMDB rating count, ten at
/// most, each once, without appearances as themselves or cameos.
final class InsightsActorTopTitlesTests: XCTestCase {
    private func entry(_ id: Int, votes: Int, movie: Bool = true, minor: Bool = false) -> FilmographyEntry {
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: id, isMovie: movie, title: "Title \(id)", year: 2000 + id, posterURL: nil, overview: nil)
        return FilmographyEntry(item: item, isOnServer: false, tmdbId: id, voteCount: votes, isMinorRole: minor)
    }

    func test_sortsByVoteCount_andKeepsTen() {
        let entries = (1...14).map { entry($0, votes: ($0 * 37) % 50) }
        let top = InsightsActorView.topTitles(entries)
        XCTAssertEqual(top.count, 10)
        XCTAssertEqual(top.map(\.voteCount), top.map(\.voteCount).sorted(by: >))
    }

    func test_minorRolesAreLeftOut() {
        let top = InsightsActorView.topTitles([entry(1, votes: 99_000, minor: true), entry(2, votes: 10)])
        XCTAssertEqual(top.map(\.tmdbId), [2])
    }

    func test_duplicateTitles_appearOnce() {
        let top = InsightsActorView.topTitles([entry(5, votes: 9), entry(5, votes: 9), entry(6, votes: 3)])
        XCTAssertEqual(top.map(\.tmdbId), [5, 6])
    }

    func test_noVoteCounts_keepOriginalOrder() {
        let top = InsightsActorView.topTitles([entry(3, votes: 0), entry(1, votes: 0), entry(2, votes: 0)])
        XCTAssertEqual(top.map(\.tmdbId), [3, 1, 2])
    }

    func test_minorRoleRules() {
        func credit(_ type: String, character: String?, order: Int? = nil, episodes: Int? = nil) -> TMDBPersonCredit {
            TMDBPersonCredit(id: 1, mediaType: type, title: "t", name: "t", character: character, job: nil,
                             posterPath: nil, releaseDate: nil, firstAirDate: nil, genreIds: nil, popularity: nil,
                             voteCount: 10, order: order, episodeCount: episodes)
        }
        XCTAssertTrue(FilmographyBuilder.isMinorRole(credit("tv", character: "Self - Guest"), isCast: true))
        XCTAssertTrue(FilmographyBuilder.isMinorRole(credit("movie", character: "Herself (archive footage)"), isCast: true))
        XCTAssertTrue(FilmographyBuilder.isMinorRole(credit("movie", character: "Waiter (uncredited)"), isCast: true))
        XCTAssertTrue(FilmographyBuilder.isMinorRole(credit("movie", character: "Man", order: 22), isCast: true))
        XCTAssertTrue(FilmographyBuilder.isMinorRole(credit("tv", character: "Doctor", episodes: 1), isCast: true))
        XCTAssertFalse(FilmographyBuilder.isMinorRole(credit("movie", character: "Clarice Starling", order: 0), isCast: true))
        XCTAssertFalse(FilmographyBuilder.isMinorRole(credit("tv", character: "Walter White", episodes: 62), isCast: true))
        XCTAssertFalse(FilmographyBuilder.isMinorRole(credit("movie", character: "Selma", order: 1), isCast: true))
    }
}

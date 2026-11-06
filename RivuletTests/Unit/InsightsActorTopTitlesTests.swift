import XCTest
@testable import Rivulet

/// The Insights actor row: TMDB's most popular titles first, ten at most, each once.
final class InsightsActorTopTitlesTests: XCTestCase {
    private func entry(_ id: Int, _ popularity: Double, movie: Bool = true) -> FilmographyEntry {
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: id, isMovie: movie, title: "Title \(id)", year: 2000 + id, posterURL: nil, overview: nil)
        return FilmographyEntry(item: item, isOnServer: false, tmdbId: id, popularity: popularity)
    }

    func test_sortsByPopularity_andKeepsTen() {
        let entries = (1...14).map { entry($0, Double($0 % 7) + Double($0) / 100) }
        let top = InsightsActorView.topTitles(entries)
        XCTAssertEqual(top.count, 10)
        XCTAssertEqual(top.map(\.popularity), top.map(\.popularity).sorted(by: >))
        XCTAssertEqual(top.first?.tmdbId, 13)
    }

    func test_duplicateTitles_appearOnce() {
        let top = InsightsActorView.topTitles([entry(5, 9), entry(5, 9), entry(6, 3)])
        XCTAssertEqual(top.map(\.tmdbId), [5, 6])
    }

    func test_noPopularity_keepsOriginalOrder() {
        let top = InsightsActorView.topTitles([entry(3, 0), entry(1, 0), entry(2, 0)])
        XCTAssertEqual(top.map(\.tmdbId), [3, 1, 2])
    }

    func test_aMovieAndAShowWithOneTMDBNumber_areTwoTitles() {
        let top = InsightsActorView.topTitles([entry(7, 2, movie: true), entry(7, 1, movie: false)])
        XCTAssertEqual(top.count, 2)
    }
}

import XCTest
@testable import Rivulet

final class PlayerRailTitleLinesTests: XCTestCase {
    func test_episode_showLarge_seasonEpisodeAndName_above() {
        let lines = UniversalPlayerViewModel.episodeRailLines(show: "Slow Horses", episode: "The Bridge", season: 1, number: 3)
        XCTAssertEqual(lines.title, "Slow Horses")
        XCTAssertEqual(lines.eyebrow, "S1 · E3 · The Bridge")
    }

    func test_special_showsOnlyTheEpisodeName() {
        let lines = UniversalPlayerViewModel.episodeRailLines(show: "Doctor Who", episode: "The Christmas Invasion", season: 0, number: 2)
        XCTAssertEqual(lines.title, "Doctor Who")
        XCTAssertEqual(lines.eyebrow, "The Christmas Invasion")
    }

    func test_noEpisodeName_keepsTheNumbers() {
        XCTAssertEqual(UniversalPlayerViewModel.episodeRailLines(show: "Show", episode: "", season: 2, number: 5).eyebrow, "S2 · E5")
    }

    func test_noShowName_fallsBackToTheEpisode() {
        let lines = UniversalPlayerViewModel.episodeRailLines(show: nil, episode: "Pilot", season: 1, number: 1)
        XCTAssertEqual(lines.title, "Pilot")
        XCTAssertNil(lines.eyebrow)
    }
}

@MainActor
final class InsightsCastFocusReturnTests: XCTestCase {
    private func cards(in view: UIView) -> [InsightsCastCardView] {
        view.subviews.flatMap { ($0 as? InsightsCastCardView).map { [$0] } ?? cards(in: $0) }
    }

    func test_focusReturnsToTheActorJustOpened() {
        let cast = (1...5).map { MediaPerson(id: "\($0)", name: "Actor \($0)", role: nil, imageURL: nil) }
        var opened: MediaPerson?
        let list = InsightsCastListView(cast: cast, trivia: nil, suppressedTriviaIDs: [], initialTab: .cast) { opened = $0 }
        let all = cards(in: list)
        XCTAssertEqual(all.count, 5)
        XCTAssertTrue(list.preferredFocusEnvironments.first === all[0])
        all[3].onPress?()
        XCTAssertEqual(opened?.id, "4")
        XCTAssertTrue(list.preferredFocusEnvironments.first === all[3])
    }
}

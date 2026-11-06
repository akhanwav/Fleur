import XCTest
@testable import Rivulet

/// A movie's year sits after its title on the same line and stays whole when
/// the title is too long; the title gives way.
@MainActor
final class PlayerRailMovieYearTests: XCTestCase {
    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
    }

    private func layout(title: String) -> (title: UILabel, year: UILabel) {
        let rail = PlayerRailView()
        rail.frame = CGRect(x: 0, y: 0, width: 1920, height: 300)
        rail.setTitle(title, eyebrow: nil, year: 2026)
        rail.layoutIfNeeded()
        let all = labels(in: rail)
        let year = all.first { $0.text == "(2026)" }!
        let titleLabel = all.first { $0.text == title }!
        return (titleLabel, year)
    }

    func test_yearFollowsTitleOnItsBaseline() {
        let (title, year) = layout(title: "Primetime")
        XCTAssertFalse(year.isHidden)
        XCTAssertGreaterThan(year.frame.minX, title.frame.maxX)
        XCTAssertEqual(year.frame.minY + year.font.ascender, title.frame.minY + title.font.ascender, accuracy: 1.5)
    }

    func test_longTitle_truncates_yearStaysWhole() {
        let long = String(repeating: "An Extremely Long Movie Title ", count: 6)
        let (title, year) = layout(title: long)
        XCTAssertGreaterThanOrEqual(year.frame.width, year.intrinsicContentSize.width - 0.5)
        XCTAssertLessThan(title.frame.width, title.intrinsicContentSize.width)
        XCTAssertGreaterThan(year.frame.minX, title.frame.maxX)
        XCTAssertLessThanOrEqual(year.frame.maxX, 1920)
    }
}

import XCTest
@testable import Rivulet

/// Which movies are several cuts, and how each cut is named. The copies are
/// the ones measured on Alpha and a shared server (October 2026).
final class MovieCutsTests: XCTestCase {

    private func v(_ id: String, _ edition: String?, _ minutes: Double) -> MovieCuts.Version {
        MovieCuts.Version(id: id, edition: edition, duration: minutes * 60)
    }

    /// The Fellowship of the Ring.
    private lazy var fellowship = [
        v("a1", nil, 178), v("a2", "Extended Cut", 228), v("a3", "Extended", 228), v("a4", "Extended Fan Cut", 193),
        v("s1", "Theatrical Cut", 178), v("s2", "Theatrical", 178), v("s3", "Theatrical Cut", 178),
    ]

    func test_lengthsOrTitlesApart_areSeveralCuts() {
        XCTAssertTrue(MovieCuts.isMultiCut(fellowship))
        XCTAssertTrue(MovieCuts.isMultiCut([v("1", "Final Cut", 117), v("2", "International Theatrical", 117)]),
                      "Blade Runner: titles only")
        XCTAssertFalse(MovieCuts.isMultiCut([v("1", nil, 117), v("2", "International Theatrical", 117)]),
                       "an untitled copy may be any cut")
        XCTAssertTrue(MovieCuts.isMultiCut([v("1", nil, 178), v("2", nil, 228)]))
    }

    func test_oneCut_sayNothing() {
        let one = [v("1", nil, 117), v("2", nil, 118), v("3", "Final Cut", 117), v("4", "The Final Cut", 117)]
        XCTAssertFalse(MovieCuts.isMultiCut(one), "one cut on several servers, worded two ways")
        XCTAssertNil(MovieCuts.label(of: one[0], among: one))
        XCTAssertEqual(MovieCuts.runtime(of: one[1]), 118 * 60, "the file's own length, cuts or not")
    }

    func test_ownTitle_elseTheSameLengthsTitle() {
        XCTAssertEqual(MovieCuts.label(of: fellowship[2], among: fellowship), "Extended")
        XCTAssertEqual(MovieCuts.name(of: fellowship[0], among: fellowship), "Theatrical Cut")
        XCTAssertEqual(MovieCuts.label(of: fellowship[0], among: fellowship), "Theatrical Cut · 2h 58m")
    }

    func test_untitled_withDisagreeingTitles_showsItsRuntime() {
        let returnOfTheKing = [v("1", nil, 201), v("2", "Remastered", 201), v("3", "Theatrical Cut", 201),
                               v("4", "Extended", 263)]
        XCTAssertNil(MovieCuts.name(of: returnOfTheKing[0], among: returnOfTheKing))
        XCTAssertEqual(MovieCuts.label(of: returnOfTheKing[0], among: returnOfTheKing), "3h 21m")
    }

    func test_twoUntitledLengths_longerIsExtended() {
        let cuts = [v("1", nil, 178), v("2", nil, 179), v("3", nil, 228)]
        XCTAssertEqual(MovieCuts.label(of: cuts[2], among: cuts), "Extended Cut · 3h 48m")
        XCTAssertEqual(MovieCuts.label(of: cuts[0], among: cuts), "2h 58m")
        let three = cuts + [v("4", nil, 193)]
        XCTAssertEqual(MovieCuts.label(of: three[2], among: three), "3h 48m", "not clear with three lengths")
    }

    func test_runtime_isTheSelectedFiles() {
        XCTAssertEqual(MovieCuts.runtime(of: fellowship[1]), 228 * 60)
        XCTAssertNil(MovieCuts.runtime(of: v("x", nil, 0)), "no file length: the metadata runtime stays")
    }

    func test_cutKey() {
        XCTAssertEqual(MovieCuts.cutKey("Extended Edition"), MovieCuts.cutKey("Extended"))
        XCTAssertEqual(MovieCuts.cutKey("The Final Cut"), MovieCuts.cutKey("Final Cut"))
        XCTAssertNotEqual(MovieCuts.cutKey("Extended Fan Cut"), MovieCuts.cutKey("Extended Cut"))
    }
}

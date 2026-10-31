import XCTest
@testable import Rivulet

/// The skip glyph carries every Settings interval's number.
final class SeekIndicatorTests: XCTestCase {
    func test_everyInterval_hasAGlyph() {
        for interval in SkipInterval.allCases {
            XCTAssertNotNil(SeekIndicator.forward(interval.rawValue).image(pointSize: 29, weight: .semibold))
            XCTAssertNotNil(SeekIndicator.backward(interval.rawValue).image(pointSize: 29, weight: .semibold))
        }
        XCTAssertEqual(SeekIndicator.forward(30).systemImage, "goforward.30")
        XCTAssertEqual(SeekIndicator.forward(20).systemImage, "goforward", "drawn: SF Symbols has no .20")
    }
}

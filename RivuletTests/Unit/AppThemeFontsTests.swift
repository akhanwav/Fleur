import XCTest
@testable import Rivulet

/// The bundled font really loads: a missing file or plist entry falls back to
/// the system font without a word.
final class AppThemeFontsTests: XCTestCase {
    func test_supportingText_isLibreFranklin_titlesAreSystem() {
        XCTAssertEqual(AppTheme.Fonts.description(23).familyName, "Libre Franklin")
        XCTAssertEqual(AppTheme.Fonts.details(25).familyName, "Libre Franklin")
        XCTAssertEqual(AppTheme.Fonts.tagline(23).familyName, "Libre Franklin")
        XCTAssertTrue(AppTheme.Fonts.tagline(23).fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertNotEqual(AppTheme.Fonts.title(48).familyName, "Libre Franklin")
    }

    func test_infoColumns_pageValuesAreLibreFranklin_popupAndHeadingsAreSystem() {
        for style in [InfoColumnView.Style.footer, .episodePage] {
            XCTAssertEqual(style.valueFont.familyName, "Libre Franklin")
            XCTAssertNotEqual(style.labelFont.familyName, "Libre Franklin")
            XCTAssertNotEqual(style.headerFont.familyName, "Libre Franklin")
        }
        XCTAssertNotEqual(InfoColumnView.Style.standard.valueFont.familyName, "Libre Franklin")
    }

    func test_licenseFileShips() {
        XCTAssertNotNil(Bundle.main.url(forResource: "LibreFranklin-OFL", withExtension: "txt"))
    }
}

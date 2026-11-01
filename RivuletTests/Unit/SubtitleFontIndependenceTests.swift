import CoreText
import XCTest
@testable import Rivulet

/// Subtitles choose their fonts themselves, so a change to the app's UI fonts
/// cannot reach them.
final class SubtitleFontIndependenceTests: XCTestCase {
    private let systemPresets: [SubtitleStylePreset] = [.defaultStyle, .largeText, .transparentBackground, .classic, .outline]

    func test_existingPresets_stayInTheSystemFont() throws {
        let system = UIFont.systemFont(ofSize: 40, weight: .medium)
        for preset in systemPresets {
            let style = try XCTUnwrap(preset.captionStyle)
            XCTAssertNil(style.fontDescriptor, preset.rawValue)
            XCTAssertEqual(style.font(ofSize: 40).fontName, system.fontName, preset.rawValue)
        }
    }

    func test_unsetSystemCaptionFont_isTheSystemFont_notTheUIFont() {
        XCTAssertEqual(CaptionStyle.default.font(ofSize: 40).fontName,
                       UIFont.systemFont(ofSize: 40, weight: .medium).fontName)
        XCTAssertNotEqual(CaptionStyle.default.font(ofSize: 40).familyName, AppTheme.Fonts.description(40).familyName)
    }

    func test_savedPresetValues_stillResolve() {
        let saved = ["defaultStyle": SubtitleStylePreset.defaultStyle, "largeText": .largeText,
                     "transparentBackground": .transparentBackground, "classic": .classic, "outline": .outline]
        for (raw, preset) in saved { XCTAssertEqual(SubtitleStylePreset(rawValue: raw), preset) }
    }

    func test_helveticaNeue_isDefaultInMedium() throws {
        let style = try XCTUnwrap(SubtitleStylePreset.helveticaNeue.captionStyle)
        XCTAssertEqual(style.font(ofSize: 40).fontName, "HelveticaNeue-Medium")
        assertLooksLikeDefault(style)
    }

    func test_libreFranklin_isDefaultInMedium() throws {
        let style = try XCTUnwrap(SubtitleStylePreset.libreFranklin.captionStyle)
        let font = style.font(ofSize: 40)
        XCTAssertEqual(font.familyName, "Libre Franklin")
        let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
        XCTAssertEqual(variation?[NSNumber(value: 0x7767_6874)]?.intValue, 500)
        assertLooksLikeDefault(style)
    }

    func test_cyclingReachesEveryPreset() {
        var seen: [SubtitleStylePreset] = []
        var preset = SubtitleStylePreset.useSystemSetting
        for _ in SubtitleStylePreset.allCases {
            seen.append(preset)
            preset = preset.advanced(bySteps: 1)
        }
        XCTAssertEqual(seen, SubtitleStylePreset.allCases)
        XCTAssertEqual(preset, .useSystemSetting)
    }

    private func assertLooksLikeDefault(_ style: CaptionStyle, line: UInt = #line) {
        var plain = style
        plain.fontDescriptor = nil
        XCTAssertEqual(plain, SubtitleStylePreset.defaultStyle.captionStyle, line: line)
    }
}

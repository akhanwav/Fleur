import XCTest
@testable import Rivulet

/// The detail page's Audio and Subtitles pickers: the English default, how a
/// saved choice finds its track on another copy, and the labels.
final class TitleTrackChoicesTests: XCTestCase {

    private func sub(_ id: String, _ codec: String, _ language: String? = "eng",
                     forced: Bool = false, sdh: Bool = false) -> SubtitleTrack {
        SubtitleTrack(id: id, index: 0, codec: codec, language: language, title: nil, extendedTitle: nil,
                      isDefault: false, isForced: forced, isHearingImpaired: sdh,
                      isEmbedded: true, externalURL: nil, isSelected: false)
    }

    private func audio(_ id: String, _ codec: String, channels: Int, language: String = "English") -> AudioTrack {
        AudioTrack(id: id, index: 0, codec: codec, profile: nil, channels: channels, channelLayout: nil,
                   language: language, title: nil, extendedTitle: nil, bitrate: nil, samplingRate: nil,
                   isDefault: false, isForced: false, isSelected: false)
    }

    // MARK: - English default

    func test_englishDefault_srtFirst_thenText_thenPGS() {
        XCTAssertEqual(EnglishSubtitleDefault.pick([sub("1", "pgs"), sub("2", "ass"), sub("3", "srt")])?.id, "3")
        XCTAssertEqual(EnglishSubtitleDefault.pick([sub("1", "pgs"), sub("2", "ass")])?.id, "2")
        XCTAssertEqual(EnglishSubtitleDefault.pick([sub("1", "pgs"), sub("2", "srt", "spa")])?.id, "1")
    }

    func test_englishDefault_fullOverForced_plainOverSDH() {
        XCTAssertEqual(EnglishSubtitleDefault.pick([sub("1", "srt", forced: true), sub("2", "pgs")])?.id, "2")
        XCTAssertEqual(EnglishSubtitleDefault.pick([sub("1", "srt", sdh: true), sub("2", "srt")])?.id, "2")
    }

    func test_englishDefault_offWithoutEnglish() {
        XCTAssertNil(EnglishSubtitleDefault.pick([sub("1", "srt", "fre"), sub("2", "pgs", "spa")]))
    }

    // MARK: - Matching on another copy

    func test_audioChoice_matchesShape_thenLanguage() {
        let intent = AudioIntent(from: audio("9", "truehd", channels: 8))
        let tracks = [audio("1", "ac3", channels: 6), audio("2", "truehd", channels: 8),
                      audio("3", "aac", channels: 2, language: "Japanese")]
        XCTAssertEqual(TitleTrackMatch.audio(intent, in: tracks)?.id, "2")
        XCTAssertEqual(TitleTrackMatch.audio(intent, in: [tracks[0], tracks[2]])?.id, "1")
    }

    func test_subtitleChoice_keepsForcedApart() {
        let intent = SubtitleIntent(from: sub("9", "srt"))
        XCTAssertEqual(TitleTrackMatch.subtitle(intent, in: [sub("1", "srt", forced: true), sub("2", "pgs")])?.id, "2")
        XCTAssertNil(TitleTrackMatch.subtitle(.off, in: [sub("1", "srt")]))
    }

    // MARK: - Labels

    func test_subtitleLabels() {
        XCTAssertEqual(TrackLabels.subtitleRow(sub("1", "srt")), "English · SRT")
        XCTAssertEqual(TrackLabels.subtitleRow(sub("1", "pgs", forced: true)), "English · PGS · Forced")
        XCTAssertEqual(TrackLabels.subtitleRow(sub("1", "srt", sdh: true)), "English SDH · SRT")
        XCTAssertEqual(TrackLabels.subtitleButton(sub("1", "srt")), "English SRT")
    }

    func test_alikeRows_gainTheirTitles() {
        let rows = TrackLabels.distinct(["English · PGS", "English · PGS", "English · SRT"],
                                        titles: ["Full", "Signs & Songs", "Full"])
        XCTAssertEqual(rows, ["English · PGS · Full", "English · PGS · Signs & Songs", "English · SRT"])
    }

    // MARK: - Store

    func test_choice_showCoversItsEpisodes_episodeOwnWins() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "titleTrackChoices")
        defer { defaults.set(saved, forKey: "titleTrackChoices") }
        defaults.removeObject(forKey: "titleTrackChoices")

        TitleTrackChoices.setSubtitle(.off, for: "plex://show/1")
        XCTAssertEqual(TitleTrackChoices.choice(guid: "plex://episode/2", showGuid: "plex://show/1")?.subtitle, .off)
        let english = SubtitleIntent(from: sub("1", "srt"))
        TitleTrackChoices.setSubtitle(english, for: "plex://episode/2")
        XCTAssertEqual(TitleTrackChoices.choice(guid: "plex://episode/2", showGuid: "plex://show/1")?.subtitle, english)
    }
}

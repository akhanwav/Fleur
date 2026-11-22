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

    /// A subtitle picked for one episode must not drop the show's audio: the
    /// player then fell back to Plex's selection (the original language).
    func test_choice_episodeSubtitle_keepsShowAudio() {
        withCleanStore {
            let english = AudioIntent(language: "eng", codec: "eac3", channels: 6)
            let sdh = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: true, codec: "srt")
            TitleTrackChoices.setAudio(english, for: "plex://show/1", at: Date(timeIntervalSince1970: 100))
            TitleTrackChoices.setSubtitle(sdh, for: "plex://episode/2", at: Date(timeIntervalSince1970: 200))
            let choice = TitleTrackChoices.choice(guid: "plex://episode/2", showGuid: "plex://show/1")
            XCTAssertEqual(choice?.audio, english)
            XCTAssertEqual(choice?.subtitle, sdh)
        }
    }

    /// The last choice stands: a show-page pick made after an episode's own
    /// covers that episode too.
    func test_choice_newerShowChoice_beatsOlderEpisodeChoice() {
        withCleanStore {
            let sdh = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: true, codec: "srt")
            TitleTrackChoices.setSubtitle(sdh, for: "plex://episode/2", at: Date(timeIntervalSince1970: 100))
            TitleTrackChoices.setSubtitle(.off, for: "plex://show/1", at: Date(timeIntervalSince1970: 200))
            XCTAssertEqual(TitleTrackChoices.choice(guid: "plex://episode/2", showGuid: "plex://show/1")?.subtitle, .off)
            TitleTrackChoices.setSubtitle(sdh, for: "plex://episode/2", at: Date(timeIntervalSince1970: 300))
            XCTAssertEqual(TitleTrackChoices.choice(guid: "plex://episode/2", showGuid: "plex://show/1")?.subtitle, sdh)
        }
    }

    /// Two English SRT tracks (full and "Dubtitle") share a shape; the saved
    /// title picks the one chosen, on the page and in the player.
    func test_sameShapeTracks_titleDecides() {
        let full = SubtitleTrack(id: "1", index: 0, codec: "srt", language: "eng", title: nil,
                                 extendedTitle: "English (SRT)", isDefault: false, isForced: false,
                                 isHearingImpaired: false, isEmbedded: true, externalURL: nil, isSelected: false)
        let dub = SubtitleTrack(id: "2", index: 0, codec: "srt", language: "eng", title: "Dubtitle",
                                extendedTitle: "Dubtitle (English SRT)", isDefault: false, isForced: false,
                                isHearingImpaired: false, isEmbedded: true, externalURL: nil, isSelected: false)
        let intent = SubtitleIntent(from: dub)
        XCTAssertEqual(TitleTrackMatch.subtitle(intent, title: dub.extendedTitle, in: [full, dub])?.id, "2")
        XCTAssertEqual(TitleTrackMatch.subtitle(intent, title: nil, in: [full, dub])?.id, "1")

        let engine = [MediaTrack(id: 15, name: "English", languageCode: "eng", codec: "srt",
                                 extendedDisplayTitle: "English (SRT)"),
                      MediaTrack(id: 16, name: "Dubtitle", languageCode: "eng", codec: "srt",
                                 extendedDisplayTitle: "Dubtitle (English SRT)")]
        XCTAssertEqual(TitleTrackMatch.subtitle(intent, title: "Dubtitle (English SRT)", in: engine)?.id, 16)
        XCTAssertEqual(TitleTrackMatch.subtitle(intent, title: "Gone", in: engine)?.id, 15)
    }

    func test_sameShapeAudio_titleDecides() {
        let tracks = [MediaTrack(id: 1, name: "Japanese", languageCode: "jpn", codec: "eac3",
                                 extendedDisplayTitle: "Japanese (EAC3 5.1)", channels: 6),
                      MediaTrack(id: 2, name: "Japanese Descriptive", languageCode: "jpn", codec: "eac3",
                                 extendedDisplayTitle: "Japanese Descriptive (EAC3 5.1)", channels: 6)]
        let intent = AudioIntent(language: "jpn", codec: "eac3", channels: 6)
        XCTAssertEqual(TitleTrackMatch.audio(intent, title: "Japanese Descriptive (EAC3 5.1)", in: tracks)?.id, 2)
        XCTAssertEqual(TitleTrackMatch.audio(intent, title: nil, in: tracks)?.id, 1)
    }

    private func withCleanStore(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "titleTrackChoices")
        defer { defaults.set(saved, forKey: "titleTrackChoices") }
        defaults.removeObject(forKey: "titleTrackChoices")
        body()
    }
}

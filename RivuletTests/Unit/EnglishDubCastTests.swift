import XCTest
@testable import Rivulet

/// The English Dub Cast row: Fribb's id map, AniList's answer, and how a
/// page's entries combine.
final class EnglishDubCastTests: XCTestCase {

    // MARK: - Fribb's list

    /// The list's shapes as served in October 2026: a show's TMDB id in a
    /// `tv` key with a season map, a film's in a `movie` list.
    private let fribb = """
    [
      {"type": "TV", "anilist_id": 140960, "tvdb_id": 405920, "themoviedb_id": {"tv": 120089},
       "season": {"tvdb": 1, "tmdb": 1}},
      {"type": "TV", "anilist_id": 158927, "tvdb_id": 405920, "themoviedb_id": {"tv": 120089},
       "season": {"tvdb": 2, "tmdb": 2}},
      {"type": "TV", "anilist_id": 21, "tvdb_id": 81797, "themoviedb_id": {"tv": 37854}},
      {"type": "MOVIE", "anilist_id": 199, "themoviedb_id": {"movie": [129]}},
      {"type": "SPECIAL", "anilist_id": 999, "themoviedb_id": {"tv": 120089}, "season": {"tmdb": 0}},
      {"type": "TV", "anilist_id": 5, "mal_id": 5},
      {"type": "TV", "mal_id": 6, "themoviedb_id": {"tv": 1}}
    ]
    """

    private func entries() throws -> [AnimeIDMap.Entry] {
        try AnimeIDMap.trim(Data(fribb.utf8))
    }

    func test_trim_keepsEntriesLinkingAniListToTMDBOrTVDB() throws {
        let trimmed = try entries()
        XCTAssertEqual(trimmed.map(\.anilist), [140960, 158927, 21, 199, 999])
        XCTAssertEqual(trimmed[0].tmdbShow, 120089)
        XCTAssertEqual(trimmed[0].tmdbSeason, 1)
        XCTAssertEqual(trimmed[3].tmdbMovies, [129])
    }

    func test_showPage_takesEverySeriesEntry_inSeasonOrder() throws {
        let picked = AnimeIDMap.select(try entries(), for: .show(tmdb: 120089, tvdb: nil, season: nil))
        XCTAssertEqual(picked.map(\.anilist), [140960, 158927], "the special is not part of the show's cast")
    }

    func test_seasonPage_takesItsSeasonsEntry() throws {
        let picked = AnimeIDMap.select(try entries(), for: .show(tmdb: 120089, tvdb: nil, season: 2))
        XCTAssertEqual(picked.map(\.anilist), [158927])
    }

    /// One Piece: one AniList entry for the whole run, with no season.
    func test_seasonPage_ofAShowKeptWhole_takesTheWholeEntry() throws {
        let picked = AnimeIDMap.select(try entries(), for: .show(tmdb: 37854, tvdb: nil, season: 23))
        XCTAssertEqual(picked.map(\.anilist), [21])
    }

    func test_tvdbMatches_whenTMDBFindsNone() throws {
        let picked = AnimeIDMap.select(try entries(), for: .show(tmdb: 1, tvdb: 405920, season: 1))
        XCTAssertEqual(picked.map(\.anilist), [140960])
    }

    func test_film_byTMDBMovieID() throws {
        XCTAssertEqual(AnimeIDMap.select(try entries(), for: .movie(tmdb: 129)).map(\.anilist), [199])
    }

    // MARK: - AniList's answer

    func test_parse_firstEnglishActor_andNoPlaceholderPhoto() throws {
        let json = """
        {"data": {"Page": {"media": [{"id": 140960, "characters": {"edges": [
          {"role": "MAIN", "node": {"name": {"full": "Loid Forger"}},
           "voiceActors": [{"id": 1, "name": {"full": "Alex Organ"},
                            "image": {"large": "https://s4.anilist.co/file/anilistcdn/staff/large/n1.png"}}]},
          {"role": "SUPPORTING", "node": {"name": {"full": "Bond Forger"}},
           "voiceActors": [{"id": 2, "name": {"full": "Someone"},
                            "image": {"large": "https://s4.anilist.co/file/anilistcdn/staff/large/default.jpg"}}]},
          {"role": "BACKGROUND", "node": {"name": {"full": "Extra"}}, "voiceActors": []}
        ]}}]}}}
        """
        let parsed = try AniListClient.parse(Data(json.utf8))
        let characters = try XCTUnwrap(parsed[140960])
        XCTAssertEqual(characters.map(\.name), ["Loid Forger", "Bond Forger", "Extra"])
        XCTAssertEqual(characters[0].actor?.name, "Alex Organ")
        XCTAssertNotNil(characters[0].actor?.image)
        XCTAssertNil(characters[1].actor?.image, "AniList's placeholder is no photo")
        XCTAssertNil(characters[2].actor)
    }

    // MARK: - Combining a show's entries

    private func character(_ name: String, _ role: String, actor id: Int?) -> AniListClient.Character {
        AniListClient.Character(role: role, name: name,
                                actor: id.map { AniListClient.VoiceActor(id: $0, name: "Actor \($0)", image: nil) })
    }

    func test_combine_mainCharactersFirst_eachActorOnce() {
        let season1 = [character("Hero", "MAIN", actor: 1), character("Friend", "SUPPORTING", actor: 2),
                       character("Nobody", "BACKGROUND", actor: nil)]
        let season2 = [character("Rival", "MAIN", actor: 3), character("Hero", "MAIN", actor: 1),
                       character("Old Man", "SUPPORTING", actor: 2)]
        let credits = EnglishDubCast.combine([season1, season2])
        XCTAssertEqual(credits.map(\.key), ["anilist:1", "anilist:3", "anilist:2"])
        XCTAssertEqual(credits[0].characters, ["Hero"])
        XCTAssertEqual(credits[2].characters, ["Friend", "Old Man"])
    }

    func test_combine_respectsTheLimit() {
        let many = (1...40).map { character("C\($0)", "SUPPORTING", actor: $0) }
        XCTAssertEqual(EnglishDubCast.combine([many]).count, EnglishDubCast.limit)
    }

    // MARK: - Gates

    private func track(_ language: String?) -> AudioTrack {
        AudioTrack(id: "1", index: 0, codec: "aac", profile: nil, channels: 2, channelLayout: nil,
                   language: language, title: nil, extendedTitle: nil, bitrate: nil, samplingRate: nil,
                   isDefault: false, isForced: false, isSelected: false)
    }

    func test_englishTrack_asPlexAndJellyfinName_it() {
        XCTAssertTrue(EnglishDubCast.isEnglish(track("English")))
        XCTAssertTrue(EnglishDubCast.isEnglish(track("eng")))
        XCTAssertTrue(EnglishDubCast.isEnglish(track("English (US)")))
        XCTAssertFalse(EnglishDubCast.isEnglish(track("Japanese")))
        XCTAssertFalse(EnglishDubCast.isEnglish(track(nil)))
    }

    func test_animation_asTheAgentsTagIt() {
        XCTAssertTrue(EnglishDubCast.isAnimation(["Action", "Animation"]))
        XCTAssertTrue(EnglishDubCast.isAnimation(["Anime"]))
        XCTAssertFalse(EnglishDubCast.isAnimation(["Drama"]))
    }

    // MARK: - Actor links

    private func credit(genres: [Int], character: String) -> TMDBPersonCredit {
        let json = """
        {"id": 1, "media_type": "tv", "name": "X", "character": "\(character)", "genre_ids": \(genres)}
        """
        return try! JSONDecoder().decode(TMDBPersonCredit.self, from: Data(json.utf8))
    }

    /// TMDB marks a dub role "(voice)", "(English Dub)" or not at all.
    func test_voiceActorLink_needsARoleInAnimation() {
        XCTAssertTrue(TMDBClient.hasAnimationVoiceCredit([credit(genres: [16, 10759], character: "Loid (voice)")]))
        XCTAssertTrue(TMDBClient.hasAnimationVoiceCredit([credit(genres: [16], character: "Hinata Hidaka (English Dub)")]))
        XCTAssertTrue(TMDBClient.hasAnimationVoiceCredit([credit(genres: [16], character: "Sister")]))
        XCTAssertFalse(TMDBClient.hasAnimationVoiceCredit([credit(genres: [18], character: "Doctor (voice)")]),
                       "a role outside animation")
        XCTAssertFalse(TMDBClient.hasAnimationVoiceCredit([credit(genres: [16], character: "Himself")]),
                       "appearing as oneself")
    }
}

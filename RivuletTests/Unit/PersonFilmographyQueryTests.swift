// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonFilmographyQueryTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PersonFilmographyQueryTests: XCTestCase {

    private func credit(_ id: Int, _ mediaType: String, title: String, character: String? = nil,
                        job: String? = nil, date: String? = nil, genres: [Int] = [],
                        popularity: Double = 0) -> TMDBPersonCredit {
        TMDBPersonCredit(id: id, mediaType: mediaType,
                         title: mediaType == "movie" ? title : nil,
                         name: mediaType == "tv" ? title : nil,
                         character: character, job: job, posterPath: nil,
                         releaseDate: mediaType == "movie" ? date : nil,
                         firstAirDate: mediaType == "tv" ? date : nil,
                         genreIds: genres, popularity: popularity)
    }

    private func entry(_ title: String, isMovie: Bool = true, tmdb: Int? = nil, onServer: Bool = false,
                       genres: [String] = [], date: String? = nil, popularity: Double = 0) -> FilmographyEntry {
        FilmographyEntry(item: PersonFilmographyTestFixtures.playableItem(title: title, isMovie: isMovie),
                         isOnServer: onServer, tmdbId: tmdb, genres: genres,
                         popularity: popularity, releaseDate: date)
    }

    /// Several characters on one title become one entry, joined in credit order.
    func test_buildMergesCharactersPerTitle() {
        let filmography = TMDBPersonFilmography(knownForDepartment: "Acting", cast: [
            credit(1, "movie", title: "The Batman", character: "Batman", date: "2022-03-04", genres: [80]),
            credit(1, "movie", title: "The Batman", character: "Bruce Wayne"),
            credit(1, "tv", title: "Same Id, Show", character: "Host"),
        ], crew: [])
        let entries = FilmographyBuilder.entries(from: filmography)
        XCTAssertEqual(entries.map(\.item.title), ["The Batman", "Same Id, Show"])
        XCTAssertEqual(entries.first?.credit, "Batman / Bruce Wayne")
        XCTAssertEqual(entries.first?.item.year, 2022)
        XCTAssertEqual(entries.first?.genres, ["Crime"])
        XCTAssertEqual(entries.first?.item.kind, .movie)
        XCTAssertEqual(entries.last?.item.kind, .show)
    }

    func test_buildSkipsTalkAndNewsShows() {
        let filmography = TMDBPersonFilmography(knownForDepartment: "Acting", cast: [
            credit(1, "tv", title: "Late Night", character: "Self", genres: [10767]),
            credit(2, "tv", title: "Evening News", character: "Self", genres: [10763]),
            credit(3, "tv", title: "Drama", character: "Lead", genres: [18]),
        ], crew: [])
        XCTAssertEqual(FilmographyBuilder.entries(from: filmography).map(\.item.title), ["Drama"])
    }

    /// A director lists what they directed, with the job as the credit line.
    func test_buildUsesCrewForNonActors() {
        let filmography = TMDBPersonFilmography(knownForDepartment: "Directing", cast: [
            credit(1, "movie", title: "Cameo", character: "Himself"),
        ], crew: [
            credit(2, "movie", title: "Directed", job: "Director"),
            credit(2, "movie", title: "Directed", job: "Writer"),
        ])
        let entries = FilmographyBuilder.entries(from: filmography)
        XCTAssertEqual(entries.map(\.item.title), ["Directed"])
        XCTAssertEqual(entries.first?.credit, "Director / Writer")
    }

    /// TV's combined genres split, so one pick matches movies and shows.
    func test_genreNamesSplitCombinedTVGenres() {
        XCTAssertEqual(TMDBGenreNames.names(for: [10765, 878]), ["Science Fiction", "Fantasy"])
    }

    /// A server title replaces its TMDB entry (keeping the credit) and is
    /// marked; server titles TMDB missed are kept.
    func test_mergeSwapsInServerItems() {
        var credited = entry("TMDB Movie", tmdb: 7)
        credited.credit = "Neo"
        let movieSameIdAsShow = entry("TMDB Show", isMovie: false, tmdb: 7)
        let server = [entry("Server Movie", tmdb: 7, onServer: true),
                      entry("Server Only", tmdb: 99, onServer: true)]
        let merged = FilmographyBuilder.merge(credits: [credited, movieSameIdAsShow], server: server)
        XCTAssertEqual(merged.map(\.item.title), ["Server Movie", "TMDB Show", "Server Only"])
        XCTAssertEqual(merged.map(\.isOnServer), [true, false, true])
        XCTAssertEqual(merged.first?.credit, "Neo")
    }

    func test_defaultQueryIsNewestFirstWithUndatedLast() {
        let entries = [entry("Old", date: "1999-03-31"), entry("Undated"), entry("New", date: "2021-12-22"),
                       entry("Middle", date: "2003-05-15")]
        XCTAssertEqual(FilmographyQuery().apply(entries).map(\.item.title), ["New", "Middle", "Old", "Undated"])
        var oldest = FilmographyQuery()
        oldest.sort = .yearAsc
        XCTAssertEqual(oldest.apply(entries).map(\.item.title), ["Old", "Middle", "New", "Undated"])
    }

    func test_queryFiltersByTypeGenresAndServer() {
        let entries = [entry("Movie A", onServer: true, genres: ["Action", "Drama"]),
                       entry("Movie B", genres: ["Action"]),
                       entry("Show C", isMovie: false, genres: ["Action", "Drama"])]
        var query = FilmographyQuery()
        query.genres = ["Action", "Drama"]
        XCTAssertEqual(query.apply(entries).map(\.item.title).sorted(), ["Movie A", "Show C"])
        query.type = .movies
        XCTAssertEqual(query.apply(entries).map(\.item.title), ["Movie A"])
        query = FilmographyQuery()
        query.onMyServersOnly = true
        XCTAssertEqual(query.apply(entries).map(\.item.title), ["Movie A"])
        // The Genre popup's live count previews a candidate without applying it.
        XCTAssertEqual(FilmographyQuery().filtered(entries, genres: ["Drama"]).count, 2)
    }

    func test_popularitySort() {
        let entries = [entry("Low", popularity: 1), entry("High", popularity: 50), entry("Mid", popularity: 9)]
        var query = FilmographyQuery()
        query.sort = .popularity
        XCTAssertEqual(query.apply(entries).map(\.item.title), ["High", "Mid", "Low"])
    }

    /// TMDB credits take over from the server rows; Known For only fills in
    /// when TMDB can't name the person.
    func test_providerFilmographyPrefersTMDBThenKnownFor() async {
        let server = [entry("Server Movie", tmdb: 7, onServer: true)]
        let withTMDB = PersonFilmographyProvider(
            serverFilmographyItems: { _ in [] },
            biography: { _ in nil },
            knownFor: { _ in [] },
            tmdbFilmography: { _ in
                TMDBPersonFilmography(knownForDepartment: "Acting", cast: [
                    TMDBPersonCredit(id: 7, mediaType: "movie", title: "TMDB Movie", name: nil,
                                     character: "Neo", job: nil, posterPath: nil, releaseDate: "1999-03-31",
                                     firstAirDate: nil, genreIds: [], popularity: 1),
                    TMDBPersonCredit(id: 8, mediaType: "movie", title: "Elsewhere", name: nil,
                                     character: "Lead", job: nil, posterPath: nil, releaseDate: nil,
                                     firstAirDate: nil, genreIds: [], popularity: 1),
                ], crew: [])
            },
            ownedItem: { _, _ in nil },
            onOtherServer: { id, _ in id == 8 })
        let person = MediaPerson(id: "p", name: "Keanu Reeves", role: nil, imageURL: nil)
        let films = await withTMDB.filmography(person: person, onServer: server)
        XCTAssertEqual(films.map(\.item.title), ["Server Movie", "Elsewhere"])
        XCTAssertEqual(films.first?.credit, "Neo")
        let marked = await withTMDB.markingOtherServers(films)
        XCTAssertEqual(marked.map(\.isOnServer), [true, true])

        let knownTitles = [entry("Known", tmdb: 3)]
        let fallback = PersonFilmographyProvider(
            serverFilmographyItems: { _ in [] },
            biography: { _ in nil },
            knownFor: { _ in knownTitles },
            tmdbFilmography: { _ in nil },
            ownedItem: { _, _ in nil },
            onOtherServer: { _, _ in false })
        let known = await fallback.filmography(person: person, onServer: server)
        XCTAssertEqual(known.map(\.item.title), ["Server Movie", "Known"])
    }
}

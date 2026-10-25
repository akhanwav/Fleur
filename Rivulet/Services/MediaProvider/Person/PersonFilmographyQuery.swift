// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonFilmographyQuery.swift
//  Rivulet
//
//  The person page's filmography as data: TMDB combined credits turned into
//  `FilmographyEntry` values (one per title, characters merged), merged with
//  the titles already on the server, and the Sort / Type / Genre / On My
//  Servers controls applied. Pure, so it unit-tests without the network.
//

import Foundation

/// Sort order for the person page's filmography.
nonisolated enum FilmographySortOption: CaseIterable {
    case yearDesc
    case yearAsc
    case titleAsc
    case titleDesc
    case popularity

    var displayName: String {
        switch self {
        case .yearDesc: "Release Year (Newest)"
        case .yearAsc: "Release Year (Oldest)"
        case .titleAsc: "Title A-Z"
        case .titleDesc: "Title Z-A"
        case .popularity: "Popularity"
        }
    }
}

/// The header controls' state. A fresh page starts at `init()`: newest
/// first, everything shown. Nothing is remembered between opens.
struct FilmographyQuery: Equatable {
    var sort: FilmographySortOption = .yearDesc
    var type: WatchlistTypeFilter = .all
    /// AND across the set: a title must carry every picked genre.
    var genres: Set<String> = []
    var onMyServersOnly = false

    /// Type, genre and server filters, unsorted. Separate so the Genre
    /// popup's live count previews a candidate selection with the same rule.
    func filtered(_ entries: [FilmographyEntry], genres candidate: Set<String>? = nil) -> [FilmographyEntry] {
        let genres = candidate ?? self.genres
        return entries.filter { entry in
            switch type {
            case .all: break
            case .movies: guard entry.item.kind == .movie else { return false }
            case .shows: guard entry.item.kind == .show else { return false }
            }
            if onMyServersOnly, !entry.isOnServer { return false }
            return genres.isSubset(of: Set(entry.genres))
        }
    }

    func apply(_ entries: [FilmographyEntry]) -> [FilmographyEntry] {
        let result = filtered(entries)
        func title(_ e: FilmographyEntry) -> String { e.item.title }
        switch sort {
        case .yearDesc:
            // Undated titles (announced, unreleased) sit after the dated ones.
            return result.sorted { a, b in
                switch (Self.date(a), Self.date(b)) {
                case let (x?, y?) where x != y: return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.popularity > b.popularity
                }
            }
        case .yearAsc:
            return result.sorted { a, b in
                switch (Self.date(a), Self.date(b)) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.popularity > b.popularity
                }
            }
        case .titleAsc:
            return result.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        case .titleDesc:
            return result.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedDescending }
        case .popularity:
            return result.sorted { $0.popularity > $1.popularity }
        }
    }

    /// Release date for ordering: TMDB's, else the server item's own date,
    /// else its year.
    private static func date(_ entry: FilmographyEntry) -> String? {
        entry.releaseDate ?? entry.item.releaseDate ?? entry.item.year.map { "\($0)" }
    }
}

enum FilmographyBuilder {
    private static let posterBase = "https://image.tmdb.org/t/p/w500"
    /// Talk and news shows: guest spots as "Self", not part of the work.
    private static let excludedGenreIDs: Set<Int> = [10763, 10767]

    /// One entry per title (ordering is `FilmographyQuery`'s). An
    /// actor's page lists their cast credits; anyone known for another
    /// department (a director) lists their crew credits instead, as does
    /// anyone with no cast credits at all.
    static func entries(from filmography: TMDBPersonFilmography) -> [FilmographyEntry] {
        let useCrew = filmography.cast.isEmpty
            || (filmography.knownForDepartment != nil && filmography.knownForDepartment != "Acting"
                && !filmography.crew.isEmpty)
        let credits = useCrew ? filmography.crew : filmography.cast

        var order: [String] = []
        var byKey: [String: (credit: TMDBPersonCredit, parts: [String])] = [:]
        for credit in credits {
            guard let mediaType = credit.mediaType, mediaType == "movie" || mediaType == "tv" else { continue }
            guard excludedGenreIDs.isDisjoint(with: credit.genreIds ?? []) else { continue }
            let key = "\(mediaType):\(credit.id)"
            let part = (useCrew ? credit.job : credit.character)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (credit, [])
            }
            if let part, !part.isEmpty, !(byKey[key]?.parts.contains(part) ?? true) {
                byKey[key]?.parts.append(part)
            }
        }

        return order.compactMap { key in
            guard let (credit, parts) = byKey[key] else { return nil }
            let isMovie = credit.mediaType == "movie"
            guard let title = (isMovie ? credit.title : credit.name), !title.isEmpty else { return nil }
            let date = (isMovie ? credit.releaseDate : credit.firstAirDate).flatMap { $0.isEmpty ? nil : $0 }
            let item = PersonItemMapper.metadataOnlyItem(
                tmdbId: credit.id, isMovie: isMovie, title: title,
                year: date.flatMap { Int($0.prefix(4)) },
                posterURL: credit.posterPath.flatMap { URL(string: posterBase + $0) },
                overview: nil)
            return FilmographyEntry(
                item: item, isOnServer: false, tmdbId: credit.id,
                credit: parts.isEmpty ? nil : parts.joined(separator: " / "),
                genres: TMDBGenreNames.names(for: credit.genreIds ?? []),
                popularity: credit.popularity ?? 0,
                releaseDate: date)
        }
    }

    /// `credits` with each title already on the server swapped for its
    /// playable server item (matched by kind + TMDB id), then the server
    /// titles TMDB didn't list appended. A matched entry keeps TMDB's
    /// credit, genres, popularity and date.
    static func merge(credits: [FilmographyEntry], server: [FilmographyEntry]) -> [FilmographyEntry] {
        var serverByKey: [String: FilmographyEntry] = [:]
        for entry in server where entry.tmdbId != nil { serverByKey[entry.key] = entry }
        var used = Set<String>()
        var result = credits.map { entry -> FilmographyEntry in
            guard let owned = serverByKey[entry.key] else { return entry }
            used.insert(entry.key)
            var merged = entry
            merged.item = owned.item
            merged.isOnServer = true
            merged.guid = owned.guid
            return merged
        }
        var seen = Set(result.map(\.key))
        for entry in server where !used.contains(entry.key) && seen.insert(entry.key).inserted {
            result.append(entry)
        }
        return result
    }
}

/// TMDB's genre ids as names. TV's combined genres ("Action & Adventure",
/// "Sci-Fi & Fantasy", "War & Politics") split into the movie names, so one
/// Genre pick matches movies and shows alike.
enum TMDBGenreNames {
    private static let table: [Int: [String]] = [
        28: ["Action"], 12: ["Adventure"], 16: ["Animation"], 35: ["Comedy"], 80: ["Crime"],
        99: ["Documentary"], 18: ["Drama"], 10751: ["Family"], 14: ["Fantasy"], 36: ["History"],
        27: ["Horror"], 10402: ["Music"], 9648: ["Mystery"], 10749: ["Romance"],
        878: ["Science Fiction"], 10770: ["TV Movie"], 53: ["Thriller"], 10752: ["War"], 37: ["Western"],
        10759: ["Action", "Adventure"], 10762: ["Kids"], 10764: ["Reality"],
        10765: ["Science Fiction", "Fantasy"], 10766: ["Soap"], 10768: ["War", "Politics"],
    ]

    static func names(for ids: [Int]) -> [String] {
        var seen = Set<String>()
        return ids.flatMap { table[$0] ?? [] }.filter { seen.insert($0).inserted }
    }
}

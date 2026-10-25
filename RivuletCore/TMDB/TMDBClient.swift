// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBClient.swift
//  Rivulet
//
//  Lightweight TMDB client that talks to TMDB's own API directly.
//  Used only for per-item features (keywords/cast/genres/directors) that
//  feed the personalized recommendation engine. Artwork (logos, backdrops)
//  comes from Plex directly.
//

import Foundation

enum TMDBMediaType: String, Codable, Sendable {
    case movie
    case tv
}

nonisolated struct TMDBKeyword: Codable, Sendable {
    let id: Int?
    let name: String?
}

nonisolated struct TMDBGenre: Codable, Sendable {
    let id: Int?
    let name: String?
}

nonisolated struct TMDBDetails: Codable, Sendable {
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case genres
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

nonisolated struct TMDBCredit: Codable, Sendable {
    let id: Int?
    let name: String?
    let job: String?
    let department: String?
    let character: String?
    let profilePath: String?
    enum CodingKeys: String, CodingKey {
        case id, name, job, department, character
        case profilePath = "profile_path"
    }
}

nonisolated struct TMDBPersonDetails: Codable, Sendable {
    let biography: String?
    let profilePath: String?
    enum CodingKeys: String, CodingKey {
        case biography
        case profilePath = "profile_path"
    }
}

/// One title in a person's TMDB combined credits (`person/{id}/combined_credits`).
/// A person credited twice on one title (two characters, or a cast and a
/// crew credit) appears once per credit.
nonisolated struct TMDBPersonCredit: Codable, Sendable {
    let id: Int
    let mediaType: String?      // "movie" | "tv"
    let title: String?          // movies
    let name: String?           // shows
    let character: String?      // cast credits
    let job: String?            // crew credits
    let posterPath: String?
    let releaseDate: String?    // movies, "YYYY-MM-DD"
    let firstAirDate: String?   // shows
    let genreIds: [Int]?
    let popularity: Double?
    enum CodingKeys: String, CodingKey {
        case id, title, name, character, job, popularity
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case genreIds = "genre_ids"
    }
}

/// A person's TMDB credits, with the department they're known for
/// ("Acting", "Directing", …) so a director's page lists what they directed.
nonisolated struct TMDBPersonFilmography: Sendable {
    let knownForDepartment: String?
    let cast: [TMDBPersonCredit]
    let crew: [TMDBPersonCredit]
}

private nonisolated struct TMDBPersonCreditsResponse: Codable, Sendable {
    let knownForDepartment: String?
    let combinedCredits: Credits?
    struct Credits: Codable, Sendable {
        let cast: [TMDBPersonCredit]?
        let crew: [TMDBPersonCredit]?
    }
    enum CodingKeys: String, CodingKey {
        case knownForDepartment = "known_for_department"
        case combinedCredits = "combined_credits"
    }
}

private nonisolated struct TMDBPersonSearchResponse: Codable, Sendable {
    let results: [Person]?
    struct Person: Codable, Sendable {
        let id: Int
        let name: String?
        let popularity: Double?
        let knownFor: [KnownFor]?
        enum CodingKeys: String, CodingKey {
            case id, name, popularity
            case knownFor = "known_for"
        }
    }
    struct KnownFor: Codable, Sendable {
        let id: Int
        let mediaType: String?
        enum CodingKeys: String, CodingKey {
            case id
            case mediaType = "media_type"
        }
    }
}

/// A title's TMDB poster and backdrop paths (relative to the image CDN).
nonisolated struct TMDBArtworkPaths: Codable, Sendable {
    let posterPath: String?
    let backdropPath: String?
    enum CodingKeys: String, CodingKey {
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

private nonisolated struct TMDBTitleSearchResponse: Codable, Sendable {
    let results: [Result]?
    struct Result: Codable, Sendable {
        let title: String?
        let name: String?
        let posterPath: String?
        let backdropPath: String?
        enum CodingKeys: String, CodingKey {
            case title, name
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
        }
    }
}

private nonisolated struct TMDBKeywordsResponse: Codable, Sendable {
    let keywords: [TMDBKeyword]?
    let results: [TMDBKeyword]?

    var allKeywords: [TMDBKeyword] {
        if let keywords { return keywords }
        if let results { return results }
        return []
    }
}

private nonisolated struct TMDBCreditsResponse: Codable, Sendable {
    let cast: [TMDBCredit]?
    let crew: [TMDBCredit]?
}

nonisolated struct TMDBEpisodeCreditsResponse: Codable, Sendable {
    let cast: [TMDBCredit]?
    let guestStars: [TMDBCredit]?
    enum CodingKeys: String, CodingKey {
        case cast
        case guestStars = "guest_stars"
    }
}

struct TMDBItemFeatures: Codable {
    var keywords: [String]
    var cast: [String]
    var directors: [String]
    var genres: [String]
    var voteAverage: Double?
    var voteCount: Int?

    mutating func merge(from other: TMDBItemFeatures) {
        keywords.append(contentsOf: other.keywords)
        cast.append(contentsOf: other.cast)
        directors.append(contentsOf: other.directors)
        genres.append(contentsOf: other.genres)
    }

    func normalized() -> TMDBItemFeatures {
        TMDBItemFeatures(
            keywords: Array(Set(keywords)),
            cast: Array(Set(cast)),
            directors: Array(Set(directors)),
            genres: Array(Set(genres)),
            voteAverage: voteAverage,
            voteCount: voteCount
        )
    }
}

private struct CachedFeatures: Codable {
    let generatedAt: Date
    let features: TMDBItemFeatures
}

final class TMDBClient: @unchecked Sendable {
    static let shared = TMDBClient()

    private let session: URLSession
    private let cacheDirectory: URL
    private let cacheTTL = TMDBConfig.localCacheTTL

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDirectory = caches.appendingPathComponent("TMDBCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func fetchFeatures(tmdbId: Int, type: TMDBMediaType) async -> TMDBItemFeatures? {
        if let cached = loadCachedFeatures(tmdbId: tmdbId, type: type) {
            return cached
        }

        do {
            async let keywordsResponse: TMDBKeywordsResponse = request(path: "\(type.rawValue)/\(tmdbId)/keywords")
            async let creditsResponse: TMDBCreditsResponse = request(path: "\(type.rawValue)/\(tmdbId)/credits")
            async let detailsResponse: TMDBDetails = request(path: "\(type.rawValue)/\(tmdbId)")

            let (keywords, credits, details) = try await (keywordsResponse, creditsResponse, detailsResponse)

            let features = TMDBItemFeatures(
                keywords: keywords.allKeywords.compactMap { $0.name?.lowercased() },
                cast: (credits.cast ?? []).prefix(8).compactMap { $0.name?.lowercased() },
                directors: (credits.crew ?? []).filter { $0.job?.lowercased() == "director" }.prefix(4).compactMap { $0.name?.lowercased() },
                genres: (details.genres ?? []).compactMap { $0.name?.lowercased() },
                voteAverage: details.voteAverage,
                voteCount: details.voteCount
            ).normalized()

            saveCachedFeatures(features, tmdbId: tmdbId, type: type)
            return features
        } catch {
            return nil
        }
    }

    // MARK: - Networking

    /// Decodes off the main actor: this class inherits the module's default
    /// MainActor isolation, and a prolific actor's combined credits run to
    /// hundreds of KB (the same reason PlexNetworkManager decodes detached).
    private func request<T: Decodable & Sendable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let req = TMDBConfig.request(path: path, queryItems: queryItems) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }

    // MARK: - Local Cache

    private func cacheURL(tmdbId: Int, type: TMDBMediaType) -> URL {
        cacheDirectory.appendingPathComponent("\(type.rawValue)_\(tmdbId).json")
    }

    private func loadCachedFeatures(tmdbId: Int, type: TMDBMediaType) -> TMDBItemFeatures? {
        let url = cacheURL(tmdbId: tmdbId, type: type)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedFeatures.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(cached.generatedAt)
        guard age < cacheTTL else { return nil }
        return cached.features
    }

    private func saveCachedFeatures(_ features: TMDBItemFeatures, tmdbId: Int, type: TMDBMediaType) {
        let cached = CachedFeatures(generatedAt: Date(), features: features)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = cacheURL(tmdbId: tmdbId, type: type)
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Actor bio

    /// Resolves an actor (by the originating title's TMDB credits + a name match)
    /// to their TMDB biography. Plex exposes no actor-bio API, so TMDB is the bio
    /// source for the person page. The PORTRAIT is intentionally NOT taken from
    /// TMDB — the page renders the Plex role thumb from first paint, and swapping
    /// in a different TMDB image seconds later is jarring. Returns nil if unresolved.
    func actorBiography(titleTmdbId: Int?, type: TMDBMediaType, actorName: String) async -> String? {
        guard let personId = await personId(titleTmdbId: titleTmdbId, type: type, name: actorName) else { return nil }
        let person: TMDBPersonDetails? = try? await request(path: "person/\(personId)")
        return person?.biography.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The TMDB person behind a credit. First by name in the originating
    /// title's credits (cast, then crew, so a director resolves too; a show's
    /// `aggregate_credits`, every season's cast, not just the latest), then by
    /// a TMDB person search on the name, preferring the person known for that
    /// title, else the most popular exact-name match. nil only when TMDB has
    /// no one by that name.
    func personId(titleTmdbId: Int?, type: TMDBMediaType, name: String) async -> Int? {
        let target = Self.normalizedName(name)
        guard !target.isEmpty else { return nil }
        if let titleTmdbId {
            let path = type == .movie ? "movie/\(titleTmdbId)/credits" : "tv/\(titleTmdbId)/aggregate_credits"
            if let credits: TMDBCreditsResponse = try? await request(path: path),
               let match = ((credits.cast ?? []) + (credits.crew ?? [])).first(where: {
                   $0.name.map(Self.normalizedName) == target }),
               let id = match.id {
                return id
            }
        }
        guard let search: TMDBPersonSearchResponse = try? await request(
            path: "search/person", queryItems: [URLQueryItem(name: "query", value: name)]) else { return nil }
        let exact = (search.results ?? []).filter { $0.name.map(Self.normalizedName) == target }
        if let titleTmdbId,
           let knownForTitle = exact.first(where: { ($0.knownFor ?? []).contains { $0.id == titleTmdbId } }) {
            return knownForTitle.id
        }
        return exact.max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }?.id
    }

    /// Names compared without case, accents, punctuation or extra spaces:
    /// "Robert Downey Jr." and "Robert Downey Jr" are one person.
    static func normalizedName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let spaced = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Every movie and show the person is credited on. nil on failure.
    func personFilmography(personId: Int) async -> TMDBPersonFilmography? {
        guard let response: TMDBPersonCreditsResponse = try? await request(
            path: "person/\(personId)",
            queryItems: [URLQueryItem(name: "append_to_response", value: "combined_credits")]
        ) else { return nil }
        return TMDBPersonFilmography(knownForDepartment: response.knownForDepartment,
                                     cast: response.combinedCredits?.cast ?? [],
                                     crew: response.combinedCredits?.crew ?? [])
    }

    // MARK: - Artwork fallback

    /// A title's poster and backdrop, by TMDB id when known, else by a title
    /// search (with the year), preferring an exact title match. For server
    /// items whose own artwork is missing or a video frame.
    func artworkPaths(tmdbId: Int?, type: TMDBMediaType, title: String, year: Int?) async -> TMDBArtworkPaths? {
        if let tmdbId, let paths: TMDBArtworkPaths = try? await request(path: "\(type.rawValue)/\(tmdbId)") {
            return paths
        }
        var query = [URLQueryItem(name: "query", value: title)]
        if let year {
            query.append(URLQueryItem(name: type == .movie ? "year" : "first_air_date_year", value: String(year)))
        }
        guard let search: TMDBTitleSearchResponse = try? await request(
            path: "search/\(type.rawValue)", queryItems: query) else { return nil }
        let results = search.results ?? []
        let target = Self.normalizedName(title)
        let match = results.first { Self.normalizedName($0.title ?? $0.name ?? "") == target } ?? results.first
        return match.map { TMDBArtworkPaths(posterPath: $0.posterPath, backdropPath: $0.backdropPath) }
    }

    // MARK: - Structured cast (Insights)

    /// Structured cast for movie or show. Returns [] on any failure —
    /// callers treat empty as "fall back to Plex roles".
    func castCredits(tmdbId: Int, type: TMDBMediaType) async -> [TMDBCredit] {
        let credits: TMDBCreditsResponse? = try? await request(path: "\(type.rawValue)/\(tmdbId)/credits")
        return credits?.cast ?? []
    }

    /// Episode-level cast: season regulars followed by episode's guest
    /// stars. TMDB's own episode-credits endpoint already returns both in
    /// one call; returns nil on failure so callers can fall back to the
    /// show-level `castCredits`.
    func episodeCastCredits(showTmdbId: Int, season: Int, episode: Int) async -> [TMDBCredit]? {
        let response: TMDBEpisodeCreditsResponse? = try? await request(
            path: "tv/\(showTmdbId)/season/\(season)/episode/\(episode)/credits")
        guard let response else { return nil }
        let merged = Self.mergedEpisodeCast(response)
        return merged.isEmpty ? nil : merged
    }

    /// Regulars first, guests; dedupe by person id (a regular also
    /// appear in guest_stars for some shows).
    static func mergedEpisodeCast(_ response: TMDBEpisodeCreditsResponse) -> [TMDBCredit] {
        let cast = response.cast ?? []
        let guests = response.guestStars ?? []
        let regularIds = Set(cast.compactMap { $0.id })
        let unique = cast + guests.filter { !regularIds.contains($0.id ?? -1) }
        return unique
    }
}

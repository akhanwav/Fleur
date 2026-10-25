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

struct TMDBKeyword: Codable {
    let id: Int?
    let name: String?
}

struct TMDBGenre: Codable, Sendable {
    let id: Int?
    let name: String?
}

struct TMDBDetails: Codable {
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case genres
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

struct TMDBCredit: Codable, Sendable {
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

struct TMDBPersonDetails: Codable, Sendable {
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
struct TMDBPersonCredit: Codable, Sendable {
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
struct TMDBPersonFilmography: Sendable {
    let knownForDepartment: String?
    let cast: [TMDBPersonCredit]
    let crew: [TMDBPersonCredit]
}

private struct TMDBPersonCreditsResponse: Codable {
    let knownForDepartment: String?
    let combinedCredits: Credits?
    struct Credits: Codable {
        let cast: [TMDBPersonCredit]?
        let crew: [TMDBPersonCredit]?
    }
    enum CodingKeys: String, CodingKey {
        case knownForDepartment = "known_for_department"
        case combinedCredits = "combined_credits"
    }
}

private struct TMDBKeywordsResponse: Codable {
    let keywords: [TMDBKeyword]?
    let results: [TMDBKeyword]?

    var allKeywords: [TMDBKeyword] {
        if let keywords { return keywords }
        if let results { return results }
        return []
    }
}

private struct TMDBCreditsResponse: Codable {
    let cast: [TMDBCredit]?
    let crew: [TMDBCredit]?
}

struct TMDBEpisodeCreditsResponse: Codable {
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

    private func request<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let req = TMDBConfig.request(path: path, queryItems: queryItems) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
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
    func actorBiography(titleTmdbId: Int, type: TMDBMediaType, actorName: String) async -> String? {
        guard let personId = await personId(titleTmdbId: titleTmdbId, type: type, name: actorName) else { return nil }
        let person: TMDBPersonDetails? = try? await request(path: "person/\(personId)")
        return person?.biography.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The TMDB person behind a credit on `titleTmdbId`, matched by name
    /// (cast first, then crew, so a director resolves too).
    func personId(titleTmdbId: Int, type: TMDBMediaType, name: String) async -> Int? {
        guard let credits: TMDBCreditsResponse = try? await request(path: "\(type.rawValue)/\(titleTmdbId)/credits") else {
            return nil
        }
        func norm(_ s: String) -> String { s.folding(options: .diacriticInsensitive, locale: .current).lowercased() }
        let target = norm(name)
        let match = ((credits.cast ?? []) + (credits.crew ?? [])).first { ($0.name.map(norm)) == target }
        return match?.id
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

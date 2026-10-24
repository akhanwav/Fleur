// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBDiscoverModels.swift
//  Rivulet
//
//  Models for TMDB list/discover endpoints used by the Discover page.
//

import Foundation

enum TMDBDiscoverSection: String, CaseIterable, Identifiable, Sendable {
    case movieTrending
    case moviePopular
    case movieNowPlaying
    case movieUpcoming
    case movieTopRated
    case tvTrending
    case tvPopular
    case tvAiringToday
    case tvOnTheAir
    case tvTopRated

    static let allCases: [TMDBDiscoverSection] = [
        .moviePopular,
        .movieNowPlaying,
        .movieUpcoming,
        .movieTopRated,
        .tvPopular,
        .tvAiringToday,
        .tvOnTheAir,
        .tvTopRated
    ]

    var id: String { rawValue }

    var mediaType: TMDBMediaType {
        switch self {
        case .movieTrending, .moviePopular, .movieNowPlaying, .movieUpcoming, .movieTopRated: return .movie
        case .tvTrending, .tvPopular, .tvAiringToday, .tvOnTheAir, .tvTopRated: return .tv
        }
    }

    var title: String {
        switch self {
        case .movieTrending: return "Trending Movies"
        case .moviePopular: return "Popular Movies"
        case .movieNowPlaying: return "Now Playing"
        case .movieUpcoming: return "Upcoming"
        case .movieTopRated: return "Top Rated Movies"
        case .tvTrending: return "Trending TV"
        case .tvPopular: return "Popular TV"
        case .tvAiringToday: return "Airing Today"
        case .tvOnTheAir: return "On The Air"
        case .tvTopRated: return "Top Rated TV"
        }
    }

    /// TMDB's own path for this section (relative to `TMDBConfig.apiBaseURL`).
    var tmdbPath: String {
        switch self {
        case .movieTrending: return "trending/movie/day"
        case .tvTrending: return "trending/tv/day"
        case .moviePopular: return "movie/popular"
        case .tvPopular: return "tv/popular"
        case .movieNowPlaying: return "movie/now_playing"
        case .movieUpcoming: return "movie/upcoming"
        case .movieTopRated: return "movie/top_rated"
        case .tvTopRated: return "tv/top_rated"
        case .tvAiringToday: return "tv/airing_today"
        case .tvOnTheAir: return "tv/on_the_air"
        }
    }
}

struct TMDBListItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let mediaType: TMDBMediaType

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
    }

    init(id: Int, title: String, overview: String?, posterPath: String?, backdropPath: String?, releaseDate: String?, voteAverage: Double?, mediaType: TMDBMediaType) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
        self.mediaType = mediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .name))
            ?? ""
        overview = try? c.decode(String.self, forKey: .overview)
        posterPath = try? c.decode(String.self, forKey: .posterPath)
        backdropPath = try? c.decode(String.self, forKey: .backdropPath)
        releaseDate = (try? c.decode(String.self, forKey: .releaseDate))
            ?? (try? c.decode(String.self, forKey: .firstAirDate))
        voteAverage = try? c.decode(Double.self, forKey: .voteAverage)
        if c.contains(.mediaType) {
            let raw = try c.decode(String.self, forKey: .mediaType)
            guard let parsed = TMDBMediaType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mediaType, in: c,
                    debugDescription: "Unknown TMDB media_type: \(raw)"
                )
            }
            mediaType = parsed
        } else {
            // Typed list endpoints (popular movies, popular tv, etc.) omit media_type.
            // The service layer stamps the correct type after decode using the section's mediaType.
            mediaType = .movie
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(posterPath, forKey: .posterPath)
        try c.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(voteAverage, forKey: .voteAverage)
        try c.encode(mediaType.rawValue, forKey: .mediaType)
    }
}

/// One `watch/providers` entry (a streaming/rental/purchase service), scoped
/// to a single region by the container that holds it.
struct TMDBWatchProvider: Codable, Sendable, Hashable {
    let providerId: Int?
    let providerName: String?
    let logoPath: String?

    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case providerName = "provider_name"
        case logoPath = "logo_path"
    }
}

/// One region's `watch/providers` offer (TMDB's `watch/providers.results.{country}`).
struct TMDBWatchProviderRegion: Codable, Sendable {
    let link: String?
    let flatrate: [TMDBWatchProvider]?
    let rent: [TMDBWatchProvider]?
    let buy: [TMDBWatchProvider]?
}

/// A TV show's `created_by` entry (TMDB has no per-episode "director" for
/// shows; this is the closest equivalent to a movie's director).
struct TMDBCreatedBy: Codable, Sendable {
    let id: Int?
    let name: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case profilePath = "profile_path"
    }
}

struct TMDBItemDetail: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?
    let genres: [TMDBGenre]
    let voteAverage: Double?
    let cast: [TMDBCredit]
    /// From the `credits` append (movies: directors live here via `job == "Director"`).
    let crew: [TMDBCredit]
    /// TV shows only (`created_by`); TMDB has no per-show "director" field.
    let createdBy: [TMDBCreatedBy]
    /// TV shows only.
    let numberOfSeasons: Int?
    /// From the `recommendations` append.
    let recommendations: [TMDBListItem]
    /// From the `watch/providers` append, already narrowed to one region by
    /// the service layer (US today).
    let watchProviders: TMDBWatchProviderRegion?
    let mediaType: TMDBMediaType

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case runtime
        case genres
        case voteAverage = "vote_average"
        case cast
        case credits
        case createdBy = "created_by"
        case numberOfSeasons = "number_of_seasons"
        case recommendations
        case watchProviders = "watch/providers"
        case mediaType = "media_type"
    }

    // Codable (not just Decodable): `encode(to:)` re-wraps crew/recommendations/
    // watchProviders back into these same nested shapes so the 30-day disk
    // cache round-trips them — without this, a cache HIT after the app
    // relaunches would silently decode back to empty crew/recommendations/
    // watchProviders even though the original network fetch had real data.
    private struct CreditsContainer: Codable { let cast: [TMDBCredit]?; let crew: [TMDBCredit]? }
    private struct RecommendationsContainer: Codable { let results: [TMDBListItem]? }
    private struct WatchProvidersContainer: Codable { let results: [String: TMDBWatchProviderRegion]? }

    init(
        id: Int,
        title: String,
        overview: String?,
        posterPath: String?,
        backdropPath: String?,
        releaseDate: String?,
        runtime: Int?,
        genres: [TMDBGenre],
        voteAverage: Double?,
        cast: [TMDBCredit],
        crew: [TMDBCredit] = [],
        createdBy: [TMDBCreatedBy] = [],
        numberOfSeasons: Int? = nil,
        recommendations: [TMDBListItem] = [],
        watchProviders: TMDBWatchProviderRegion? = nil,
        mediaType: TMDBMediaType
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.runtime = runtime
        self.genres = genres
        self.voteAverage = voteAverage
        self.cast = cast
        self.crew = crew
        self.createdBy = createdBy
        self.numberOfSeasons = numberOfSeasons
        self.recommendations = recommendations
        self.watchProviders = watchProviders
        self.mediaType = mediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        guard let t = (try? c.decode(String.self, forKey: .title))
                   ?? (try? c.decode(String.self, forKey: .name)) else {
            throw DecodingError.keyNotFound(
                CodingKeys.title,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: "Expected 'title' or 'name'")
            )
        }
        title = t
        overview = try? c.decode(String.self, forKey: .overview)
        posterPath = try? c.decode(String.self, forKey: .posterPath)
        backdropPath = try? c.decode(String.self, forKey: .backdropPath)
        releaseDate = (try? c.decode(String.self, forKey: .releaseDate))
            ?? (try? c.decode(String.self, forKey: .firstAirDate))
        runtime = try? c.decode(Int.self, forKey: .runtime)
        genres = (try? c.decode([TMDBGenre].self, forKey: .genres)) ?? []
        voteAverage = try? c.decode(Double.self, forKey: .voteAverage)
        // The bare detail endpoint has no top-level "cast" key — it only
        // appears nested under "credits" via `append_to_response=credits`.
        let creditsContainer = try? c.decode(CreditsContainer.self, forKey: .credits)
        cast = creditsContainer?.cast ?? (try? c.decode([TMDBCredit].self, forKey: .cast)) ?? []
        crew = creditsContainer?.crew ?? []
        createdBy = (try? c.decode([TMDBCreatedBy].self, forKey: .createdBy)) ?? []
        numberOfSeasons = try? c.decode(Int.self, forKey: .numberOfSeasons)
        let recommendationsContainer = try? c.decode(RecommendationsContainer.self, forKey: .recommendations)
        recommendations = recommendationsContainer?.results ?? []
        let watchProvidersContainer = try? c.decode(WatchProvidersContainer.self, forKey: .watchProviders)
        watchProviders = watchProvidersContainer?.results?["US"]
        if c.contains(.mediaType) {
            let raw = try c.decode(String.self, forKey: .mediaType)
            guard let parsed = TMDBMediaType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mediaType, in: c,
                    debugDescription: "Unknown TMDB media_type: \(raw)"
                )
            }
            mediaType = parsed
        } else {
            // Typed detail endpoints omit media_type.
            // The service layer stamps the correct type after decode.
            mediaType = .movie
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(posterPath, forKey: .posterPath)
        try c.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(voteAverage, forKey: .voteAverage)
        try c.encode(cast, forKey: .cast)
        // Re-wrapped into the SAME nested shapes `init(from:)` reads, so a
        // disk-cache round trip restores them exactly (see the container
        // types' doc comment above).
        try c.encode(CreditsContainer(cast: cast, crew: crew), forKey: .credits)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(numberOfSeasons, forKey: .numberOfSeasons)
        try c.encode(RecommendationsContainer(results: recommendations), forKey: .recommendations)
        if let watchProviders {
            try c.encode(WatchProvidersContainer(results: ["US": watchProviders]), forKey: .watchProviders)
        }
        try c.encode(mediaType.rawValue, forKey: .mediaType)
    }
}

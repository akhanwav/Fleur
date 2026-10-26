// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBMediaMapper.swift
//  Rivulet
//
//  TMDB DTO -> agnostic-type translations. Mirror of PlexMediaMapper for
//  the TMDB MetadataSource side.
//

import Foundation

enum TMDBMediaMapper {
    static let providerID = "tmdb"

    private static let backdropBase = "https://image.tmdb.org/t/p/original"
    // w780 (not w500): posters appear on large carousel/detail cards where w500
    // visibly upscales. Still small enough that row cards downsample cheaply.
    private static let posterBase = "https://image.tmdb.org/t/p/w780"
    // w185: cast circles and watch-provider logos are small (CastCell.circleSize,
    // a ~60pt chip) — no reason to pull a larger profile/logo image.
    private static let profileBase = "https://image.tmdb.org/t/p/w185"
    private static let logoBase = "https://image.tmdb.org/t/p/w92"

    private static func profileURL(_ path: String?) -> URL? {
        path.flatMap { URL(string: "\(profileBase)\($0)") }
    }

    private static func logoURL(_ path: String?) -> URL? {
        path.flatMap { URL(string: "\(logoBase)\($0)") }
    }

    /// TMDB ids are not globally unique — id 100 can exist as a movie AND a TV
    /// show. `MediaItemRef.itemID` encodes both so callers that only have a ref
    /// can disambiguate without a second round-trip. Format: "{movie|tv}:{id}".
    /// Decoding tolerates bare numeric itemIDs for backward compatibility with
    /// anything persisted before this format landed.
    static func encodeItemID(tmdbId: Int, type: TMDBMediaType) -> String {
        "\(type.rawValue):\(tmdbId)"
    }

    static func decodeItemID(_ itemID: String) -> (tmdbId: Int, type: TMDBMediaType)? {
        let parts = itemID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let type = TMDBMediaType(rawValue: parts[0]),
              let id = Int(parts[1]) else { return nil }
        return (id, type)
    }

    static func item(_ tmdb: TMDBListItem) -> MediaItem {
        // TMDBMediaType currently only has .movie / .tv (TMDBClient.swift).
        // If TMDB person results are ever supported, extend both that enum
        // and this mapping to cover .person.
        let kind: MediaKind = (tmdb.mediaType == .movie) ? .movie : .show
        let year: Int? = {
            guard let raw = tmdb.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
            return Int(raw)
        }()
        let artwork = MediaArtwork(
            poster: tmdb.posterPath.flatMap { URL(string: "\(posterBase)\($0)") },
            backdrop: tmdb.backdropPath.flatMap { URL(string: "\(backdropBase)\($0)") },
            thumbnail: tmdb.posterPath.flatMap { URL(string: "\(posterBase)\($0)") },
            logo: nil
        )
        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: encodeItemID(tmdbId: tmdb.id, type: tmdb.mediaType)),
            kind: kind,
            title: tmdb.title,
            sortTitle: nil,
            overview: tmdb.overview,
            year: year,
            releaseDate: tmdb.releaseDate,
            contentRating: nil,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: artwork,
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    /// A watchlist entry as a metadata-only item, for what needs only the
    /// title's TMDB id (Ways to Watch on a Watchlist tile). nil without one.
    static func item(_ entry: PlexWatchlistItem) -> MediaItem? {
        guard let tmdbId = entry.tmdbId else { return nil }
        let type: TMDBMediaType = entry.type == .movie ? .movie : .tv
        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: encodeItemID(tmdbId: tmdbId, type: type)),
            kind: entry.type == .movie ? .movie : .show,
            title: entry.title,
            sortTitle: nil,
            overview: nil,
            year: entry.year,
            releaseDate: nil,
            contentRating: nil,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: entry.posterURL, backdrop: nil, thumbnail: entry.posterURL, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    static func detail(_ tmdb: TMDBItemDetail) -> MediaItemDetail {
        let cast = tmdb.cast.map { credit in
            MediaPerson(
                id: "\(credit.id ?? 0)",
                name: credit.name ?? "",
                role: credit.character,
                imageURL: profileURL(credit.profilePath),
                titleTmdbId: tmdb.id,
                titleIsMovie: tmdb.mediaType == .movie,
                tmdbPersonId: credit.id
            )
        }
        // TMDB has no per-show "director" credit — movies get one from the
        // crew (job == "Director"); shows use `created_by` instead.
        let directors: [MediaPerson]
        if tmdb.mediaType == .movie {
            directors = tmdb.crew
                .filter { ($0.job ?? "").caseInsensitiveCompare("Director") == .orderedSame }
                .map { credit in
                    MediaPerson(
                        id: "\(credit.id ?? 0)",
                        name: credit.name ?? "",
                        role: "Director",
                        imageURL: profileURL(credit.profilePath),
                        titleTmdbId: tmdb.id,
                        titleIsMovie: true,
                        tmdbPersonId: credit.id
                    )
                }
        } else {
            directors = tmdb.createdBy.map { creator in
                MediaPerson(
                    id: "\(creator.id ?? 0)",
                    name: creator.name ?? "",
                    role: "Creator",
                    imageURL: profileURL(creator.profilePath),
                    titleTmdbId: tmdb.id,
                    titleIsMovie: false,
                    tmdbPersonId: creator.id
                )
            }
        }
        // Re-stub a TMDBListItem so we can reuse `item(_:)` for the embedded MediaItem.
        let stub = TMDBListItem(
            id: tmdb.id,
            title: tmdb.title,
            overview: tmdb.overview,
            posterPath: tmdb.posterPath,
            backdropPath: tmdb.backdropPath,
            releaseDate: tmdb.releaseDate,
            voteAverage: tmdb.voteAverage,
            mediaType: tmdb.mediaType
        )
        let runtime: TimeInterval? = tmdb.runtime.map { TimeInterval($0 * 60) }
        var embedded = item(stub)
        embedded = MediaItem(
            ref: embedded.ref,
            kind: embedded.kind,
            title: embedded.title,
            sortTitle: embedded.sortTitle,
            overview: embedded.overview,
            year: embedded.year,
            releaseDate: embedded.releaseDate,
            contentRating: embedded.contentRating,
            runtime: runtime,
            parentRef: embedded.parentRef,
            grandparentRef: embedded.grandparentRef,
            episodeNumber: embedded.episodeNumber,
            seasonNumber: embedded.seasonNumber,
            childProgress: embedded.childProgress,
            userState: embedded.userState,
            artwork: embedded.artwork,
            parentArtwork: embedded.parentArtwork,
            grandparentArtwork: embedded.grandparentArtwork
        )
        return MediaItemDetail(
            item: embedded,
            tagline: nil,
            genres: tmdb.genres.compactMap(\.name),
            studios: [],
            cast: cast,
            directors: directors,
            writers: [],
            chapters: [],
            mediaSources: [],
            trailerURL: nil,
            externalTrailerURL: tmdb.youtubeTrailerKey.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") },
            contentRating: nil,
            rating: MediaRating(tmdb.voteAverage, source: .tmdb),
            nextEpisode: nil,
            collections: [],
            seasonCount: tmdb.mediaType == .tv ? tmdb.numberOfSeasons : nil
        )
    }

    /// Maps a title's `watch/providers` region into the agnostic
    /// `MediaWatchAvailability` the below-fold's "Where to Watch" section reads.
    static func watchAvailability(_ region: TMDBWatchProviderRegion?) -> MediaWatchAvailability {
        guard let region else { return .empty }
        func options(_ providers: [TMDBWatchProvider]?, kind: MediaWatchOption.Kind) -> [MediaWatchOption] {
            (providers ?? []).compactMap { provider in
                guard let name = provider.providerName else { return nil }
                return MediaWatchOption(kind: kind, providerName: name, logoURL: logoURL(provider.logoPath))
            }
        }
        let combined = options(region.flatrate, kind: .stream)
            + options(region.rent, kind: .rent)
            + options(region.buy, kind: .buy)
        return MediaWatchAvailability(link: region.link.flatMap(URL.init(string:)), options: combined)
    }
}

extension MediaItem {
    /// True when the item exists only as external metadata (TMDB-mapped, no
    /// playback-capable MediaProvider registered for its ref). Surfaces
    /// should offer Watchlist as the primary action instead of Play, and
    /// hide watched-state controls.
    var isMetadataOnly: Bool { ref.providerID == TMDBMediaMapper.providerID }

    /// The TMDB id for metadata-only items (nil for provider-backed items).
    var tmdbID: Int? {
        guard isMetadataOnly else { return nil }
        return TMDBMediaMapper.decodeItemID(ref.itemID)?.tmdbId
    }
}

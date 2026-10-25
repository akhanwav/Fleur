// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ArtworkFallback.swift
//  Rivulet
//
//  TMDB artwork for a server item whose own is missing or wrong. Plex hands
//  out exactly what the server stored: an item no agent matched has a frame
//  of the video as its "poster" and often no background art at all, so the
//  app has nothing better to ask that server for. Callers decide when the
//  server's art is wrong (a landscape image in a poster slot, no backdrop, a
//  backdrop far below screen size); this finds the title on TMDB and returns
//  its poster (w780) and backdrop (original size). Cached for the session.
//

import Foundation

actor ArtworkFallback {
    static let shared = ArtworkFallback()

    /// What a lookup knows about the title.
    struct Query: Hashable, Sendable {
        let tmdbId: Int?
        let isMovie: Bool
        let title: String
        let year: Int?
    }

    private static let posterBase = "https://image.tmdb.org/t/p/w780"
    private static let backdropBase = "https://image.tmdb.org/t/p/original"

    private var cache: [Query: TMDBArtworkPaths?] = [:]
    private var inFlight: [Query: Task<TMDBArtworkPaths?, Never>] = [:]

    func poster(for query: Query) async -> URL? {
        await paths(for: query)?.posterPath.flatMap { URL(string: Self.posterBase + $0) }
    }

    func backdrop(for query: Query) async -> URL? {
        await paths(for: query)?.backdropPath.flatMap { URL(string: Self.backdropBase + $0) }
    }

    private func paths(for query: Query) async -> TMDBArtworkPaths? {
        if let cached = cache[query] { return cached }
        if let task = inFlight[query] { return await task.value }
        let task = Task {
            await TMDBClient.shared.artworkPaths(tmdbId: query.tmdbId, type: query.isMovie ? .movie : .tv,
                                                 title: query.title, year: query.year)
        }
        inFlight[query] = task
        let result = await task.value
        inFlight[query] = nil
        cache[query] = result
        return result
    }
}

extension ArtworkFallback.Query {
    /// The title a Plex item's poster or backdrop belongs to: an episode's or
    /// season's is its show's. nil for music, people and other non-video.
    init?(_ meta: PlexMetadata) {
        switch meta.type {
        case "movie":
            guard let title = meta.title else { return nil }
            self.init(tmdbId: meta.tmdbId, isMovie: true, title: title, year: meta.year)
        case "show":
            guard let title = meta.title else { return nil }
            self.init(tmdbId: meta.tmdbId, isMovie: false, title: title, year: meta.year)
        case "episode", "season":
            guard let title = meta.grandparentTitle ?? meta.parentTitle else { return nil }
            self.init(tmdbId: nil, isMovie: false, title: title, year: nil)
        default:
            return nil
        }
    }

    /// A MediaItem's: movies and shows only (an episode tile shows its
    /// show's poster, which the show's own page falls back for).
    init?(_ item: MediaItem) {
        switch item.kind {
        case .movie: self.init(tmdbId: item.tmdbID, isMovie: true, title: item.title, year: item.year)
        case .show: self.init(tmdbId: item.tmdbID, isMovie: false, title: item.title, year: item.year)
        default: return nil
        }
    }
}

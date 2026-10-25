// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One title in a person's filmography, plus whether it exists on the user's server.
struct FilmographyEntry: Hashable, Sendable {
    var item: MediaItem        // playable (plex provider) when on the selected server, else metadata-only ("tmdb")
    /// On any of the user's servers: the selected one (`item` is then its
    /// playable copy) or another one this account can reach.
    var isOnServer: Bool
    var guid: String? = nil    // plex://movie/... or plex://show/..., for matching across server and Discover
    var tmdbId: Int? = nil
    /// The person's credit on the title: character name(s), or the job for crew.
    var credit: String? = nil
    var genres: [String] = []
    var popularity: Double = 0
    /// "YYYY-MM-DD", or nil when TMDB has no date (unreleased titles).
    var releaseDate: String? = nil

    /// Stable identity across the server and TMDB sources: kind + TMDB id
    /// when known, else the item's own ref.
    var key: String { tmdbId.map { "\(item.kind)-\($0)" } ?? "\(item.ref.providerID)|\(item.ref.itemID)" }

    /// `titles` minus any already in `onServer`, matched by plex guid or by TMDB
    /// id within the same kind (movie and TV TMDB ids share a number space).
    static func excluding(_ onServer: [FilmographyEntry], from titles: [FilmographyEntry]) -> [FilmographyEntry] {
        func tmdbKey(_ e: FilmographyEntry) -> String? { e.tmdbId.map { "\(e.item.kind)-\($0)" } }
        let guids = Set(onServer.compactMap(\.guid))
        let tmdbKeys = Set(onServer.compactMap(tmdbKey))
        return titles.filter { title in
            !(title.guid.map(guids.contains) ?? false) && !(tmdbKey(title).map(tmdbKeys.contains) ?? false)
        }
    }
}

/// Fully resolved data backing the person detail page.
struct PersonDetail: Hashable, Sendable {
    let id: String             // Discover person key (role tagKey) or a synthetic fallback id
    let name: String
    let biography: String?
    let portraitURL: URL?
    let movies: [FilmographyEntry]   // server entries sorted first
    let shows: [FilmographyEntry]    // server entries sorted first
}

/// Seam the view controller depends on. The concrete Plex/Discover wiring lives behind it.
protocol PersonFilmographyProviding: Sendable {
    func load(person: MediaPerson) async throws -> PersonDetail
    /// Plex Discover's Known For titles, unfiltered. Loaded separately so it
    /// never holds up the server rows.
    func knownFor(person: MediaPerson) async -> [FilmographyEntry]
    /// The person's full filmography: TMDB's combined credits (movies and
    /// shows) with `onServer`'s titles merged in, Known For when TMDB can't
    /// name the person. Loaded after `load` so the bio never waits on it.
    func filmography(person: MediaPerson, onServer: [FilmographyEntry]) async -> [FilmographyEntry]
    /// `entries` with every title on another of the user's servers marked.
    /// Slow on its first call each session (it indexes those servers).
    func markingOtherServers(_ entries: [FilmographyEntry]) async -> [FilmographyEntry]
}

extension PersonFilmographyProviding {
    func knownFor(person: MediaPerson) async -> [FilmographyEntry] { [] }
    func filmography(person: MediaPerson, onServer: [FilmographyEntry]) async -> [FilmographyEntry] { onServer }
    func markingOtherServers(_ entries: [FilmographyEntry]) async -> [FilmographyEntry] { entries }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AnimeIDMap.swift
//  Rivulet
//
//  Which AniList entries a TMDB or TVDB title is. AniList stores no TMDB or
//  TVDB ids, so the map comes from Fribb's anime-lists
//  (github.com/Fribb/anime-lists), a community list built from
//  anime-offline-database and Anime-Lists/anime-lists. Its full file is
//  about 7.5 MB; this keeps only the entries that link an AniList id to a
//  TMDB or TVDB id (a few hundred KB), refreshed once a week with a
//  conditional request.
//
//  Measured on the October 2026 list: a TMDB show id maps to every AniList
//  entry that is part of it, each with the TMDB and TVDB season it covers
//  (Attack on Titan 9 entries, Gintama 12), or one entry with no season when
//  AniList keeps the whole run as one (One Piece). A film maps through a
//  list of TMDB movie ids.
//

import Foundation
import os

nonisolated private let animeMapLog = Logger(subsystem: "com.rivulet.app", category: "AnimeIDMap")

actor AnimeIDMap {
    static let shared = AnimeIDMap()

    nonisolated struct Entry: Codable, Equatable, Sendable {
        let anilist: Int
        /// AniList's format as the list names it: TV, ONA, OVA, SPECIAL, MOVIE.
        let type: String?
        let tmdbShow: Int?
        let tmdbMovies: [Int]
        let tvdb: Int?
        let tmdbSeason: Int?
        let tvdbSeason: Int?
    }

    /// The title a detail page shows.
    nonisolated enum Title: Equatable, Sendable {
        case movie(tmdb: Int)
        /// `season` nil: the whole show.
        case show(tmdb: Int?, tvdb: Int?, season: Int?)
    }

    private nonisolated struct Stored: Codable {
        let fetchedAt: Date
        let etag: String?
        let entries: [Entry]
    }

    static let sourceURL = URL(string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json")!
    static let refreshInterval: TimeInterval = 7 * 86_400

    private var stored: Stored?
    private var loadTask: Task<Stored?, Never>?

    private var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnimeIDMap.json")
    }

    /// The AniList entries for `title`, in season order. Reads the trimmed
    /// copy (downloading it the first time); a copy older than a week is
    /// used as it is while a refresh runs behind it.
    func entries(for title: Title) async -> [Entry] {
        guard let stored = await current() else { return [] }
        return Self.select(stored.entries, for: title)
    }

    private func current() async -> Stored? {
        if stored == nil, let data = try? Data(contentsOf: fileURL) {
            stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
        if let stored {
            if Date().timeIntervalSince(stored.fetchedAt) > Self.refreshInterval, loadTask == nil {
                loadTask = Task { await self.refresh(from: stored) }
            }
            return stored
        }
        if let loadTask { return await loadTask.value }
        let task = Task { await self.refresh(from: nil) }
        loadTask = task
        return await task.value
    }

    /// A conditional fetch: an unchanged list answers 304 and only the date moves.
    private func refresh(from previous: Stored?) async -> Stored? {
        defer { loadTask = nil }
        var request = URLRequest(url: Self.sourceURL, timeoutInterval: 120)
        if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await ForegroundGate.shared.data(for: request, in: .shared, always: true)
            let http = response as? HTTPURLResponse
            let next: Stored
            if http?.statusCode == 304, let previous {
                next = Stored(fetchedAt: Date(), etag: previous.etag, entries: previous.entries)
            } else if http?.statusCode == 200 {
                next = Stored(fetchedAt: Date(), etag: http?.value(forHTTPHeaderField: "ETag"),
                              entries: try Self.trim(data))
            } else {
                animeMapLog.error("[AnimeIDMap] fetch answered \(http?.statusCode ?? -1, privacy: .public)")
                return previous
            }
            stored = next
            try? JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            animeMapLog.info("[AnimeIDMap] \(next.entries.count, privacy: .public) entries")
            return next
        } catch {
            animeMapLog.error("[AnimeIDMap] fetch failed: \(error.localizedDescription, privacy: .public)")
            return previous
        }
    }

    // MARK: - Pure

    /// The list's entries that link an AniList id to TMDB or TVDB.
    nonisolated static func trim(_ data: Data) throws -> [Entry] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        func int(_ value: Any?) -> Int? {
            if let number = value as? Int { return number }
            if let text = value as? String { return Int(text) }
            return nil
        }
        return raw.compactMap { object in
            guard let anilist = int(object["anilist_id"]) else { return nil }
            let tmdb = object["themoviedb_id"] as? [String: Any]
            let movies: [Int] = (tmdb?["movie"] as? [Any])?.compactMap(int) ?? int(tmdb?["movie"]).map { [$0] } ?? []
            let season = object["season"] as? [String: Any]
            let entry = Entry(anilist: anilist, type: object["type"] as? String,
                              tmdbShow: int(tmdb?["tv"]), tmdbMovies: movies, tvdb: int(object["tvdb_id"]),
                              tmdbSeason: int(season?["tmdb"]), tvdbSeason: int(season?["tvdb"]))
            guard entry.tmdbShow != nil || !entry.tmdbMovies.isEmpty || entry.tvdb != nil else { return nil }
            return entry
        }
    }

    /// A show's series entries (TV and ONA; its films, OVAs and specials
    /// have pages of their own), matched by TMDB id first and by TVDB id when
    /// TMDB finds none. A season takes the entries for that season in the
    /// numbering of the id that matched, or else an entry that covers the
    /// whole run. A film takes the entries listing its TMDB id.
    nonisolated static func select(_ entries: [Entry], for title: Title) -> [Entry] {
        switch title {
        case .movie(let tmdb):
            return entries.filter { $0.tmdbMovies.contains(tmdb) }.sorted { $0.anilist < $1.anilist }
        case .show(let tmdb, let tvdb, let season):
            let series = entries.filter { $0.type == "TV" || $0.type == "ONA" }
            var matched = tmdb.map { id in series.filter { $0.tmdbShow == id } } ?? []
            var bySeason: (Entry) -> Int? = { $0.tmdbSeason }
            if matched.isEmpty, let tvdb {
                matched = series.filter { $0.tvdb == tvdb }
                bySeason = { $0.tvdbSeason }
            }
            let ordered = matched.sorted {
                (bySeason($0) ?? 0, $0.anilist) < (bySeason($1) ?? 0, $1.anilist)
            }
            guard let season else { return ordered }
            let exact = ordered.filter { bySeason($0) == season }
            return exact.isEmpty ? ordered.filter { bySeason($0) == nil } : exact
        }
    }
}

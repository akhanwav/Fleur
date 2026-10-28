// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EpisodeSummaryFill.swift
//  Rivulet
//
//  Episode descriptions a server lacks, from TMDB. Some libraries carry none
//  at all (every episode of a show, on one server), while TMDB has them. Only
//  an empty summary is filled; a server's own text is never replaced.
//
//  Matched by the show's TMDB id plus season and episode number, so it is
//  skipped where that numbering is not TMDB's: year-numbered seasons
//  (Formula 1's 2026), a season or episode TMDB does not have (absolute
//  anime numbering past TMDB's season), or an air date a year or more away
//  from the server's.
//

import Foundation

actor EpisodeSummaryFill {
    static let shared = EpisodeSummaryFill()

    /// Show TMDB ids by server and show ratingKey, nil when none resolves.
    private var showIDs: [String: Task<Int?, Never>] = [:]

    /// `episodes` with each empty episode summary filled where TMDB has one.
    func fill(_ episodes: [PlexMetadata], serverURL: String, authToken: String) async -> [PlexMetadata] {
        guard episodes.contains(where: Self.needsSummary) else { return episodes }
        var out = episodes
        var seasons: [String: [Int: TMDBDiscoverService.SeasonEpisode]] = [:]
        for index in out.indices where Self.needsSummary(out[index]) {
            let episode = out[index]
            guard let showKey = episode.grandparentRatingKey,
                  let season = episode.parentIndex, let number = episode.index,
                  let tvId = await showTMDBId(showKey, serverURL: serverURL, authToken: authToken)
            else { continue }
            let key = "\(tvId):\(season)"
            if seasons[key] == nil {
                let list = await TMDBDiscoverService.shared.seasonEpisodes(tvId: tvId, season: season) ?? []
                seasons[key] = Dictionary(list.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { first, _ in first })
            }
            guard let match = seasons[key]?[number],
                  let text = match.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  Self.yearsAgree(episode.originallyAvailableAt, match.airDate)
            else { continue }
            out[index].summary = text
        }
        return out
    }

    /// An episode with no summary, in a season numbered the way TMDB numbers
    /// them (not by year).
    static func needsSummary(_ item: PlexMetadata) -> Bool {
        guard item.type == "episode",
              (item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let season = item.parentIndex, (0...100).contains(season),
              item.index != nil
        else { return false }
        return true
    }

    /// False only when both dates are known and a year or more apart.
    static func yearsAgree(_ server: String?, _ tmdb: String?) -> Bool {
        guard let a = server.flatMap({ Int($0.prefix(4)) }), let b = tmdb.flatMap({ Int($0.prefix(4)) }) else {
            return true
        }
        return abs(a - b) <= 1
    }

    private func showTMDBId(_ showKey: String, serverURL: String, authToken: String) async -> Int? {
        let key = "\(serverURL)|\(showKey)"
        if let task = showIDs[key] { return await task.value }
        let task = Task<Int?, Never> {
            guard let show = try? await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: showKey, includeGuids: true)
            else { return nil }
            var ids = ShowExternalIDs(
                tmdb: show.guid.flatMap(PlexMetadata.extractTmdbId),
                tvdb: show.guid.flatMap(PlexMetadata.extractTvdbId),
                imdb: show.guid.flatMap(PlexMetadata.extractImdbId))
            for guid in show.Guid?.compactMap(\.id) ?? [] {
                if ids.tmdb == nil { ids.tmdb = PlexMetadata.extractTmdbId(from: guid) }
                if ids.tvdb == nil { ids.tvdb = PlexMetadata.extractTvdbId(from: guid) }
                if ids.imdb == nil { ids.imdb = PlexMetadata.extractImdbId(from: guid) }
            }
            return await InsightsShowIDResolver.shared.resolve(ids)
        }
        showIDs[key] = task
        return await task.value
    }
}

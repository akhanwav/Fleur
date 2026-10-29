// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeasonShows.swift
//  Rivulet
//
//  The show each season tile opens. A season's own page looked itself up by
//  the season's guid, which a second library's copy of the same show often
//  does not share (it found one copy where the show has three), and its
//  hub item carries no background, so the card stretched a 225 px poster.
//

import Foundation

@MainActor
enum SeasonShows {
    private static var shows: [MediaItemRef: MediaItem] = [:]

    /// `items` with every season replaced by its show, in order. A season
    /// whose show cannot be read stays a season.
    static func shows(for items: [MediaItem]) async -> [MediaItem] {
        await withTaskGroup(of: (Int, MediaItem?).self) { group in
            for (index, item) in items.enumerated() where item.kind == .season {
                group.addTask { (index, await show(for: item)) }
            }
            var out = items
            for await (index, show) in group {
                if let show { out[index] = show }
            }
            return out
        }
    }

    private static func show(for season: MediaItem) async -> MediaItem? {
        guard let showRef = season.parentRef else { return nil }
        if let known = shows[showRef] { return known }
        guard let provider = MediaProviderRegistry.shared.provider(for: showRef.providerID),
              let show = try? await provider.fullDetail(for: showRef).item,
              show.kind == .show else { return nil }
        shows[showRef] = show
        return show
    }
}

/// Where an episode tile in Recently Added opens. A season added one episode
/// at a time lists its newest episode; when nothing in that season has been
/// watched or started, the tile opens the season's first episode instead, so
/// Play starts the season from the top.
@MainActor
enum SeasonStarts {
    /// `items` with each such episode replaced by its season's first.
    static func firstEpisodes(for items: [MediaItem]) async -> [MediaItem] {
        await withTaskGroup(of: (Int, MediaItem?).self) { group in
            for (index, item) in items.enumerated() where item.kind == .episode && isUntouched(item) {
                group.addTask { (index, await start(for: item)) }
            }
            var out = items
            for await (index, first) in group {
                if let first { out[index] = first }
            }
            return out
        }
    }

    private static func start(for episode: MediaItem) async -> MediaItem? {
        guard let season = episode.parentRef,
              let provider = MediaProviderRegistry.shared.provider(for: season.providerID),
              let episodes = try? await provider.children(of: season) else { return nil }
        return seasonStart(in: episodes, for: episode)
    }

    /// The season's first episode when no episode in it is watched or
    /// started; nil to keep `episode` (also when it is already the first).
    nonisolated static func seasonStart(in episodes: [MediaItem], for episode: MediaItem) -> MediaItem? {
        guard isUntouched(episode), episodes.allSatisfy(isUntouched) else { return nil }
        let first = episodes.filter { $0.episodeNumber != nil }
            .min { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
        return first?.ref == episode.ref ? nil : first
    }

    nonisolated private static func isUntouched(_ episode: MediaItem) -> Bool {
        !episode.userState.isPlayed && episode.userState.viewOffset <= 0
    }
}

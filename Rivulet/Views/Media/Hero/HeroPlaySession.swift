// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroPlaySession.swift
//  Rivulet
//
//  Resolves "play immediately" targets for hero-carousel items.
//  Movies and episodes play directly; shows/seasons resolve to the OnDeck
//  episode, falling back to the first episode of the first season.
//

import Foundation
import os.log

private let heroPlayLog = Logger(subsystem: "com.rivulet.app", category: "HeroPlay")

enum HeroPlaySession {
    /// Returns a metadata item that is ready to play.
    ///
    /// - For movies and episodes, the input is returned unchanged.
    /// - For shows and seasons, the resolver calls `getFullMetadata(includeOnDeck=1)`
    ///   and prefers `OnDeck.Metadata.first`. When no OnDeck episode exists it
    ///   walks to the first season's first episode.
    /// - On any error, the original item is returned so the caller can fall
    ///   back to the standard detail-view flow.
    static func resolvePlaybackTarget(
        for item: PlexMetadata,
        serverURL: String,
        authToken: String
    ) async -> PlexMetadata {
        guard let type = item.type, type == "show" || type == "season",
              let ratingKey = item.ratingKey
        else {
            return item
        }

        let network = PlexNetworkManager.shared
        do {
            let full = try await network.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            if let onDeckItem = full.OnDeck?.Metadata?.first {
                heroPlayLog.info("[HeroPlay] Resolved show=\(ratingKey, privacy: .public) → OnDeck ep \(onDeckItem.ratingKey ?? "?", privacy: .public)")
                return await fetchFullIfPossible(
                    onDeckItem,
                    serverURL: serverURL,
                    authToken: authToken
                )
            }

            if type == "season" {
                let children = try await network.getChildren(
                    serverURL: serverURL,
                    authToken: authToken,
                    ratingKey: ratingKey
                )
                // Already a season — children are the episodes. Start at the
                // first UNPLAYED one, not blindly at E01 (a rewatched season
                // would otherwise always replay its first episode).
                if let target = firstUnplayed(in: children) {
                    heroPlayLog.info("[HeroPlay] Season \(ratingKey, privacy: .public) → first unplayed ep \(target.ratingKey ?? "?", privacy: .public)")
                    return await fetchFullIfPossible(
                        target,
                        serverURL: serverURL,
                        authToken: authToken
                    )
                }
            } else {
                // No On Deck: every episode, in order, through the shared rule.
                let episodes = try await network.getAllLeaves(
                    serverURL: serverURL,
                    authToken: authToken,
                    ratingKey: ratingKey
                )
                let index = EpisodePicker.nextUpIndex(
                    inProgress: episodes.map { ($0.viewOffset ?? 0) > 0 && ($0.viewCount ?? 0) == 0 },
                    played: episodes.map { ($0.viewCount ?? 0) > 0 })
                if let target = index.map({ episodes[$0] }) {
                    heroPlayLog.info("[HeroPlay] Show \(ratingKey, privacy: .public) → \(target.ratingKey ?? "?", privacy: .public)")
                    return await fetchFullIfPossible(
                        target,
                        serverURL: serverURL,
                        authToken: authToken
                    )
                }
            }
        } catch {
            heroPlayLog.error("[HeroPlay] Resolution failed for \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return item
    }

    /// Same rule as `EpisodePicker.firstUnplayed`, in Plex's currency: resume an
    /// episode that's underway, else the first unwatched one, else restart at
    /// the first. Plex marks watched via `viewCount` and tracks a resume point
    /// in `viewOffset` independently.
    private static func firstUnplayed(in episodes: [PlexMetadata]) -> PlexMetadata? {
        func isPlayed(_ m: PlexMetadata) -> Bool { (m.viewCount ?? 0) > 0 }
        func isInProgress(_ m: PlexMetadata) -> Bool { (m.viewOffset ?? 0) > 0 && !isPlayed(m) }
        return episodes.first(where: isInProgress)
            ?? episodes.first(where: { !isPlayed($0) })
            ?? episodes.first
    }

    /// Upgrade a hub-derived episode stub to a fully-loaded metadata blob so the
    /// player has stream info. Returns the original item on failure.
    private static func fetchFullIfPossible(
        _ item: PlexMetadata,
        serverURL: String,
        authToken: String
    ) async -> PlexMetadata {
        guard let key = item.ratingKey else { return item }
        do {
            return try await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: key
            )
        } catch {
            return item
        }
    }
}

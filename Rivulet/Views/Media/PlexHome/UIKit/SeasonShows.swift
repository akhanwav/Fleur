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

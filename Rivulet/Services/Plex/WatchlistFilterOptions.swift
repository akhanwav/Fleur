// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchlistFilterOptions.swift
//  Rivulet
//
//  Sort and type-filter options for the Watchlist grid. Persisted per Plex
//  profile through LibrarySettingsManager, same as the library grid's sort.
//

import Foundation

/// Sort order for the Watchlist grid. "Date Added" has no reliable per-item
/// timestamp in Plex's Discover watchlist response — its `addedAt` mirrors
/// the title's own catalog date, not when the user added it to their
/// watchlist (confirmed against a live response: an entry's `addedAt`
/// matched its `originallyAvailableAt` release date exactly). So "Date
/// Added" falls back to the list's own order instead of a timestamp sort —
/// see `PlexHomeViewController.filteredSortedWatchlistItems`.
nonisolated enum WatchlistSortOption: String, Codable {
    case dateAddedDesc
    case dateAddedAsc
    case titleAsc
    case titleDesc
    case yearDesc
    case yearAsc

    var displayName: String {
        switch self {
        case .dateAddedDesc: "Date Added"
        case .dateAddedAsc: "Date Added (Oldest)"
        case .titleAsc: "Title A-Z"
        case .titleDesc: "Title Z-A"
        case .yearDesc: "Release Year (Newest)"
        case .yearAsc: "Release Year (Oldest)"
        }
    }
}

/// Type filter for the Watchlist grid.
nonisolated enum WatchlistTypeFilter: String, Codable, CaseIterable {
    case all
    case movies
    case shows

    var displayName: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "Shows"
        }
    }
}

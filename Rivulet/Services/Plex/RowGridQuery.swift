// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RowGridQuery.swift
//  Rivulet
//
//  What a capped row's View All grid asks Plex for. Unfiltered and in the
//  row's own order, the grid pages the row's own key, so it lists exactly what
//  the row did. A sort or a filter moves it to the library listing the row
//  reads from, and Plex does the filtering: a listing carries at most two
//  genres a title (Colony lists 2 of its 8), so the app cannot match genres.
//
//  Measured on PMS 1.43.4:
//  - a repeated `genre=` is AND (Horror 31, Comedy 22, both 8); a comma is OR.
//  - episodes filter by their show's genre (`show.genre`); shows filter by
//    quality through their episodes (`episode.resolution`).
//  - `resolution` takes 4k, 1080, 720 and 480.
//  - `/library/all` takes the same filters across every library.
//  - hub endpoints (`/hubs/...`) ignore all of them, so a curated row has no
//    listing: its grid only sorts, in the app.
//

import Foundation

nonisolated struct RowGridQuery: Equatable, Sendable {

    enum Sort: Equatable, Sendable { case row, title, year }

    enum ItemType: Int, Equatable, Sendable {
        case movie = 1, show = 2, season = 3, episode = 4

        var displayName: String {
            switch self {
            case .movie: return "Movies"
            case .show: return "Shows"
            case .season: return "Seasons"
            case .episode: return "Episodes"
            }
        }
    }

    enum Quality: String, CaseIterable, Equatable, Sendable {
        case uhd = "4k", fullHD = "1080", hd = "720", sd = "480"

        var displayName: String {
            switch self {
            case .uhd: return "4K"
            case .fullHD: return "1080p"
            case .hd: return "720p"
            case .sd: return "SD"
            }
        }
    }

    struct Genre: Hashable, Sendable {
        let id: String
        let title: String
    }

    struct Choices: Equatable, Sendable {
        var sort = Sort.row
        /// nil: the row's own type.
        var type: ItemType?
        /// AND: a title must carry every one.
        var genres: Set<Genre> = []
        var quality: Quality?

        var isDefault: Bool { sort == .row && type == nil && genres.isEmpty && quality == nil }
    }

    /// The library listing behind a row.
    struct Listing: Equatable, Sendable {
        /// `/library/sections/<id>/all`, or `/library/all` across libraries.
        let path: String
        let sectionID: String?
        /// The row's own filters, without its type and sort.
        let filters: [URLQueryItem]
        let type: ItemType?
        let sort: String?
    }

    let rowKey: String
    let rowIdentifier: String?
    /// nil when Plex cannot filter the row (a curated hub).
    let listing: Listing?

    /// `libraryType` answers a section's own type for a key that names none.
    init(rowKey: String, rowIdentifier: String?, libraryType: (String) -> ItemType? = { _ in nil }) {
        self.rowKey = rowKey
        self.rowIdentifier = rowIdentifier
        listing = Self.listing(for: rowKey, libraryType: libraryType)
    }

    private static let pagingNames: Set<String> = ["X-Plex-Container-Start", "X-Plex-Container-Size"]

    private static func listing(for key: String, libraryType: (String) -> ItemType?) -> Listing? {
        guard let components = URLComponents(string: key) else { return nil }
        let items = (components.queryItems ?? []).filter { !pagingNames.contains($0.name) }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let path = components.path
        let parts = path.split(separator: "/")
        if parts.count == 4, parts[0] == "library", parts[1] == "sections", parts[3] == "all" {
            let section = String(parts[2])
            let type = value("type").flatMap(Int.init).flatMap(ItemType.init) ?? libraryType(section)
            return Listing(path: path, sectionID: section,
                           filters: items.filter { $0.name != "type" && $0.name != "sort" },
                           type: type, sort: value("sort"))
        }
        // Recently Added, on Home or a library page. A personal-media row
        // (`personal=1`) has no listing that matches it.
        if path == "/hubs/home/recentlyAdded", value("personal") == nil,
           let type = value("type").flatMap(Int.init).flatMap(ItemType.init) {
            let section = value("sectionID")
            return Listing(path: section.map { "/library/sections/\($0)/all" } ?? "/library/all",
                           sectionID: section, filters: [], type: type, sort: "addedAt:desc")
        }
        return nil
    }

    /// The Sort menu's name for the row's own order.
    var rowSortName: String {
        switch listing?.sort?.split(separator: ":").first {
        case "addedAt": return "Date Added"
        case "originallyAvailableAt": return "Release Date"
        case "lastViewedAt": return "Last Watched"
        case "audienceRating", "rating": return "Rating"
        case "titleSort": return "Title"
        case "year": return "Release Year"
        default: return "Default"
        }
    }

    /// What Type can narrow to; empty when the row holds one kind only.
    var typeOptions: [ItemType] {
        switch listing?.type {
        case .show, .season, .episode: return [.show, .episode]
        default: return []
        }
    }

    /// Plex can filter the row (Type, Genre and Quality apply).
    var canFilter: Bool { listing != nil }

    /// The type a listing returns under these choices.
    func type(for choices: Choices) -> ItemType? { choices.type ?? listing?.type }

    /// The genre list to offer: a show's genres for an episode or a season.
    func genreType(for choices: Choices) -> ItemType? {
        switch type(for: choices) {
        case .movie: return .movie
        case .show, .season, .episode: return .show
        case nil: return nil
        }
    }

    /// A curated row's whole list, sorted in the app (Plex cannot sort a hub).
    static func sortedInApp(_ items: [MediaItem], by sort: Sort) -> [MediaItem] {
        switch sort {
        case .row:
            return items
        case .title:
            return items.sorted {
                ($0.sortTitle ?? $0.title).localizedStandardCompare($1.sortTitle ?? $1.title) == .orderedAscending
            }
        case .year:
            // Newest first; a title with no year goes last. Stable for ties.
            return items.enumerated().sorted { lhs, rhs in
                let l = lhs.element.year ?? .min, r = rhs.element.year ?? .min
                return l != r ? l > r : lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    /// The key the grid pages under `choices`: the row's own while nothing
    /// differs from the row, else the filtered listing.
    func key(for choices: Choices) -> String {
        guard !choices.isDefault, let listing else { return rowKey }
        let type = type(for: choices)
        var items = listing.filters
        if let type { items.append(URLQueryItem(name: "type", value: "\(type.rawValue)")) }
        let sort: String? = switch choices.sort {
        case .row: listing.sort
        case .title: "titleSort"
        case .year: "year:desc"
        }
        if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
        let genreField = type == .episode || type == .season ? "show.genre" : "genre"
        // Repeated, not comma-joined: repeated is AND.
        for genre in choices.genres.sorted(by: { $0.id < $1.id }) {
            items.append(URLQueryItem(name: genreField, value: genre.id))
        }
        if let quality = choices.quality {
            let field = type == .show || type == .season ? "episode.resolution" : "resolution"
            items.append(URLQueryItem(name: field, value: quality.rawValue))
        }
        var components = URLComponents()
        components.path = listing.path
        components.queryItems = items
        return components.string ?? rowKey
    }
}

/// Home and library rows that page from the server stop at `limit` tiles; a
/// row with more ends in a View All tile (`ViewAllTileCell`).
nonisolated enum RowCap {
    static let limit = 15

    /// The row's tiles, and whether a View All tile follows them. `total` is
    /// the server's count when it sent one.
    static func capped<Item>(_ items: [Item], total: Int?) -> (items: [Item], viewAll: Bool) {
        (Array(items.prefix(limit)), max(total ?? 0, items.count) > limit)
    }
}

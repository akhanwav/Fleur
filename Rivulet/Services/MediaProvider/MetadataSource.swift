// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MetadataSource.swift
//  Rivulet
//
//  Read-only catalog backend (TMDB today, IMDB/TVDB/Trakt later).
//  Distinct from MediaProvider — sources can't play, don't have user state,
//  don't have libraries. They produce MediaItems that drop into the same
//  carousels and detail views.
//

import Foundation

protocol MetadataSource: Sendable {
    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem]
    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail
    func search(_ query: String) async throws -> [MediaItem]
    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem]
    /// Where this title can be streamed, rented, or bought (US region). Used
    /// by the "Where to Watch" below-fold section for items with no
    /// playback-capable MediaProvider.
    func watchAvailability(for ref: MediaItemRef) async throws -> MediaWatchAvailability
}

/// One streaming/rental/purchase option for a title, from a MetadataSource's
/// watch-provider data. Provider-agnostic (not TMDB-specific) even though
/// TMDB is the only source today — mirrors `CuratedSection` below.
struct MediaWatchOption: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable { case stream, rent, buy }
    let kind: Kind
    let providerName: String
    let logoURL: URL?
    var id: String { "\(kind.rawValue):\(providerName)" }
}

struct MediaWatchAvailability: Sendable {
    let link: URL?
    let options: [MediaWatchOption]
    static let empty = MediaWatchAvailability(link: nil, options: [])
}

enum CuratedSection: String, Sendable, CaseIterable, Identifiable, Hashable, Codable {
    case moviePopular
    case movieNowPlaying
    case movieUpcoming
    case movieTopRated
    case tvPopular
    case tvAiringToday
    case tvOnTheAir
    case tvTopRated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moviePopular: return "Popular Movies"
        case .movieNowPlaying: return "Now Playing"
        case .movieUpcoming: return "Upcoming"
        case .movieTopRated: return "Top Rated Movies"
        case .tvPopular: return "Popular TV"
        case .tvAiringToday: return "Airing Today"
        case .tvOnTheAir: return "On The Air"
        case .tvTopRated: return "Top Rated TV"
        }
    }
}

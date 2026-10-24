// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBMetadataSource.swift
//  Rivulet
//
//  TMDB implementation of MetadataSource. Wraps the existing
//  TMDBDiscoverService and translates DTOs through TMDBMediaMapper.
//

import Foundation

final class TMDBMetadataSource: MetadataSource {
    private let service: TMDBDiscoverService

    init(service: TMDBDiscoverService = .shared) {
        self.service = service
    }

    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem] {
        guard let plexSection = TMDBDiscoverSection(rawValue: section.rawValue) else {
            return []
        }
        let raw = await service.fetchSection(plexSection)
        return raw.map { TMDBMediaMapper.item($0) }
    }

    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail {
        guard ref.providerID == TMDBMediaMapper.providerID,
              let (tmdbId, type) = TMDBMediaMapper.decodeItemID(ref.itemID) else {
            throw MediaProviderError.notFound
        }
        guard let detail = await service.fetchDetail(tmdbId: tmdbId, type: type) else {
            throw MediaProviderError.notFound
        }
        return TMDBMediaMapper.detail(detail)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        // TMDBDiscoverService doesn't currently expose a /search endpoint.
        // Discover view doesn't search TMDB today; add when needed.
        return []
    }

    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem] {
        guard ref.providerID == TMDBMediaMapper.providerID,
              let (tmdbId, type) = TMDBMediaMapper.decodeItemID(ref.itemID) else {
            throw MediaProviderError.notFound
        }
        // Rides the same cached `fetchDetail` call the detail page already
        // makes (append_to_response=recommendations) — no extra round-trip.
        guard let detail = await service.fetchDetail(tmdbId: tmdbId, type: type) else {
            return []
        }
        return detail.recommendations.map { TMDBMediaMapper.item($0) }
    }

    func watchAvailability(for ref: MediaItemRef) async throws -> MediaWatchAvailability {
        guard ref.providerID == TMDBMediaMapper.providerID,
              let (tmdbId, type) = TMDBMediaMapper.decodeItemID(ref.itemID) else {
            throw MediaProviderError.notFound
        }
        guard let detail = await service.fetchDetail(tmdbId: tmdbId, type: type) else {
            return .empty
        }
        return TMDBMediaMapper.watchAvailability(detail.watchProviders)
    }
}

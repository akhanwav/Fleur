// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldContentLoader.swift
//  Rivulet
//
//  Loads the below-fold detail content (seasons, episodes, cast/crew, related)
//  for the UIKit expanded detail. Decoupled from any view — it just fetches
//  through the agnostic `MediaProvider` and returns a value.
//
//  The host (container / VC) calls `load(for:detail:)` when its item is set,
//  then feeds the result into EpisodeCell / SeasonPillView / CastCell /
//  PosterCell. Wiring that into the container is a later, runtime-verified
//  step; this loader is independently testable.
//
//  The collection row and Related come from the same `related(for:kind:)`
//  call.
//

import Foundation

/// The below-fold content for one detail item.
struct BelowFoldContent: Sendable {
    var seasons: [MediaItem] = []
    /// Episodes unified across seasons (shows/episodes) or the season's
    /// episodes (season route).
    var episodes: [MediaItem] = []
    var cast: [MediaPerson] = []
    var directors: [MediaPerson] = []
    var trailers: [BelowFoldTrailer] = []
    var extras: [BelowFoldTrailer] = []   // non-trailer extras (behind the scenes, etc.)
    var related: [MediaItem] = []
    /// The collection row (Plex's collection hub for a movie or show, minus
    /// this item), from the same `related(for:kind:)` call as `related`.
    var collection: CollectionRow?
    /// Default season to select in the pill bar.
    var selectedSeason: MediaItem?
    /// Full detail for the About + Information/Languages/Accessibility block
    /// (genres, contentRating, rating, studios, mediaSources, synopsis, year).
    var detail: MediaItemDetail?
    /// The SHOW's detail when the opened item is an episode/season. The About
    /// card always describes the SHOW (the episode specifics live in the chrome
    /// at the top), while Languages/Accessibility stay episode-level (the file).
    /// nil for movies and show-level details (use `detail`).
    var showDetail: MediaItemDetail?

    /// TMDB recommendations ("More Like This") — metadata-only items only.
    /// Distinct from `related` (Plex's `/related` hub), which stays Plex-only.
    var moreLikeThis: [MediaItem] = []
    /// TMDB watch/providers — metadata-only items only.
    var watchAvailability: MediaWatchAvailability?
    /// Cross-server check ("On Your Servers"): every Plex title and every
    /// unowned one.
    /// `.checking` on first render; the host patches in the real answer once
    /// `OtherServersAvailabilityChecker` (slow on its first call this session)
    /// resolves. nil means "not applicable" (Jellyfin, or an unmatched item).
    var serverAvailability: ServerAvailability?

    var hasEpisodes: Bool { !episodes.isEmpty }
    var hasCast: Bool { !cast.isEmpty || !directors.isEmpty }
}

/// The unowned detail's On Your Servers answer.
nonisolated enum ServerAvailability: Hashable, Sendable {
    case checking
    case notFound
    case found([ServerCopyEntry])
}

/// One copy of an unowned title on another accessible server: a focusable
/// entry that switches the page to that copy.
nonisolated struct ServerCopyEntry: Hashable, Sendable {
    let machineId: String
    /// `DetailCopy.id`: one server can hold the title in several libraries.
    var copyID: String { "\(machineId):\(ratingKey)" }
    let ratingKey: String
    let serverName: String
    /// Best version's quality ("4K · Dolby Vision · …") for a movie, the
    /// episode count for a show, led by "Resume" when that server holds a
    /// resume point.
    let summary: String?
    let target: WaysToWatchTarget
}

struct BelowFoldTrailer: Hashable, Sendable {
    let id: String
    let title: String
    let artworkURL: URL?
    let durationFormatted: String?
    var subtype: ExtraSubtype = .unknown
    /// Plex's handle for actually PLAYING this extra, which is not always the
    /// same thing as `id`. User-added (disc-ripped) extras carry a real library
    /// ratingKey; Plex's own IVA-supplied extras carry only a `key` path like
    /// `/services/iva/assets/...`. Feeding the latter to /library/metadata/{id}
    /// 404s, which is what made trailer playback fail more often than not.
    var playbackKey: String?
}

@MainActor
final class BelowFoldContentLoader {

    /// Load all below-fold content for `item`. `detail` (if the chrome already
    /// fetched it) supplies cast/directors without a second round-trip; if nil,
    /// it's fetched here. Any sub-fetch failure degrades to empty for that
    /// section rather than failing the whole load.
    func load(for item: MediaItem, detail: MediaItemDetail?) async -> BelowFoldContent {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            // No playback-capable provider for this ref (a Watchlist/Discover
            // title not on any of this account's servers): fall back to the
            // read-only metadata source (TMDB), mirroring the two-registry
            // pattern MediaDetailChromeView.fetchDetail already uses for the
            // hero above. Without this, the below-fold stayed permanently
            // empty for every metadata-only item.
            guard let source = MetadataSourceRegistry.shared.source(for: item.ref.providerID) else {
                return BelowFoldContent()
            }
            return await loadFromMetadataSource(source, item: item, detail: detail)
        }

        var content = BelowFoldContent()

        // Cast / directors come from the full detail (reuse the chrome's if
        // present, otherwise fetch). Not via `??` — its RHS is a non-async
        // autoclosure and can't host the await.
        let resolvedDetail: MediaItemDetail?
        if let detail {
            resolvedDetail = detail
        } else {
            resolvedDetail = try? await provider.fullDetail(for: item.ref)
        }
        content.cast = resolvedDetail?.cast ?? []
        content.directors = resolvedDetail?.directors ?? []
        content.detail = resolvedDetail
        // Real Plex extras, split into Trailers vs other Extras (behind the
        // scenes, featurettes, etc.) by the extra's type.
        let fallbackArt = item.artwork.thumbnail ?? item.artwork.backdrop ?? item.artwork.poster
        func makeTrailer(_ extra: MediaItemDetail.Extra) -> BelowFoldTrailer {
            BelowFoldTrailer(
                id: extra.id,
                title: extra.title,
                artworkURL: extra.thumbnailURL ?? fallbackArt,
                durationFormatted: extra.duration.map(Self.formatTrailerDuration),
                subtype: extra.subtype,
                playbackKey: extra.playbackKey
            )
        }
        let allExtras = resolvedDetail?.extras ?? []
        content.trailers = allExtras.filter { $0.isTrailer }.map(makeTrailer)
        content.extras = allExtras.filter { !$0.isTrailer }.map(makeTrailer)

        // Seasons + episodes (TV route), keyed off the item kind exactly like
        // the SwiftUI loaders.
        switch item.kind {
        case .show:
            content.seasons = (try? await provider.children(of: item.ref)) ?? []
            content.selectedSeason = content.seasons.first
            content.episodes = (try? await provider.allEpisodes(of: item.ref)) ?? []

        case .episode:
            if let showRef = item.grandparentRef {
                content.seasons = (try? await provider.children(of: showRef)) ?? []
                let currentSeasonID = item.parentRef?.itemID
                content.selectedSeason = content.seasons.first(where: { $0.ref.itemID == currentSeasonID })
                    ?? content.seasons.first
                content.episodes = (try? await provider.allEpisodes(of: showRef)) ?? []
                // About card describes the SHOW, not this episode.
                content.showDetail = try? await provider.fullDetail(for: showRef)
            }

        case .season:
            if let showRef = item.parentRef {
                content.seasons = (try? await provider.children(of: showRef)) ?? []
                content.selectedSeason = content.seasons.first(where: { $0.ref.itemID == item.ref.itemID })
                    ?? content.seasons.first
                content.showDetail = try? await provider.fullDetail(for: showRef)
            }
            content.episodes = (try? await provider.children(of: item.ref)) ?? []

        default:
            break  // movies: no seasons/episodes
        }

        // Related row and the collection row: one `/related` call feeds both.
        if let related = try? await provider.related(for: item.ref, kind: item.kind) {
            content.related = related.items
            content.collection = related.collection
        }

        // On Your Servers on every Plex title: every copy on every server,
        // filled in by `loadServerAvailability` once the lookup answers.
        if item.ref.isPlex, content.detail?.plexGuid != nil { content.serverAvailability = .checking }

        return content
    }

    /// The below-fold for a metadata-only item (TMDB, no Plex/Jellyfin
    /// provider for its ref). No episodes/trailers/extras/related/collection
    /// — those are provider-specific hub calls this item has no server for.
    /// Cast, directors, recommendations and watch availability all ride the
    /// same cached `TMDBDiscoverService.fetchDetail` call (append_to_response),
    /// so this costs one network round trip, not four.
    private func loadFromMetadataSource(_ source: MetadataSource, item: MediaItem, detail: MediaItemDetail?) async -> BelowFoldContent {
        var content = BelowFoldContent()
        let resolvedDetail: MediaItemDetail?
        if let detail {
            resolvedDetail = detail
        } else {
            resolvedDetail = try? await source.itemDetail(item.ref)
        }
        content.cast = resolvedDetail?.cast ?? []
        content.directors = resolvedDetail?.directors ?? []
        content.detail = resolvedDetail
        content.moreLikeThis = (try? await source.recommendations(for: item.ref)) ?? []
        content.watchAvailability = try? await source.watchAvailability(for: item.ref)
        // The cross-server check is slow on its first call this session
        // (pages every other server's library), so it starts in "checking"
        // and the host patches in the real answer once it resolves —
        // mirroring how `loadAdvisory` below patches the About card.
        content.serverAvailability = .checking
        return content
    }

    /// Cross-server availability for a metadata-only item — deferred exactly
    /// like `loadAdvisory`, because `OtherServersAvailabilityChecker` can be
    /// slow on its first call this session (pages every other server's
    /// library once, then caches for the rest of the session). Each match is
    /// then read on its own server for the entry's quality and resume line.
    func loadServerAvailability(for item: MediaItem, detail: MediaItemDetail?) async -> ServerAvailability? {
        let checker = OtherServersAvailabilityChecker.shared
        let copies: [OtherServersAvailabilityChecker.ServerCopy]
        if let guid = detail?.plexGuid {
            copies = await checker.copies(plexGuid: guid)
        } else if let (tmdbId, type) = TMDBMediaMapper.decodeItemID(item.ref.itemID) {
            copies = await checker.copies(forTmdbId: tmdbId, type: type)
        } else {
            return nil
        }
        guard !copies.isEmpty else { return .notFound }
        let entries = await withTaskGroup(of: ServerCopyEntry.self) { group in
            for copy in copies {
                group.addTask { await Self.entry(for: copy) }
            }
            var entries: [ServerCopyEntry] = []
            for await entry in group { entries.append(entry) }
            return entries
        }
        // `copies` is already in the user's server order.
        let order = copies.map(\.id)
        return .found(entries.sorted { (order.firstIndex(of: $0.copyID) ?? 0) < (order.firstIndex(of: $1.copyID) ?? 0) })
    }

    /// A copy's entry. A failed metadata read still yields a playable entry,
    /// just without its summary line.
    private static func entry(for copy: OtherServersAvailabilityChecker.ServerCopy) async -> ServerCopyEntry {
        let target = WaysToWatchTarget.remote(serverURL: copy.serverURL, token: copy.token,
                                              ratingKey: copy.ratingKey, mediaID: nil)
        guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
            serverURL: copy.serverURL, authToken: copy.token, ratingKey: copy.ratingKey
        ) else { return ServerCopyEntry(machineId: copy.machineId, ratingKey: copy.ratingKey,
                                        serverName: copy.serverName, summary: nil, target: target) }
        var parts: [String] = []
        if meta.type == "show" {
            if let count = meta.leafCount { parts.append(count == 1 ? "1 episode" : "\(count) episodes") }
        } else {
            if meta.isInProgress { parts.append("Resume") }
            let detail = PlexMediaMapper.detail(meta, providerID: "plex:\(copy.machineId)",
                                                serverURL: copy.serverURL, authToken: copy.token)
            if let best = VersionRanking.ordered(detail.mediaSources).first {
                parts.append(VersionPicker.rowLabel(best))
            }
        }
        return ServerCopyEntry(machineId: copy.machineId, ratingKey: copy.ratingKey, serverName: copy.serverName,
                               summary: parts.isEmpty ? nil : parts.joined(separator: " · "),
                               target: target)
    }

    /// Deferred Common Sense Media fetch — runs AFTER the below-fold renders so
    /// the rich advisory (Plex Discover, network) never blocks the initial layout.
    func loadAdvisory(for item: MediaItem) async -> ContentAdvisory? {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return nil }
        return (try? await provider.contentAdvisory(for: item.ref)) ?? nil
    }

    /// "1m" / "2m 30s" / "45s" — feeds the on-thumbnail ▶ duration badge.
    private static func formatTrailerDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        if m == 0 { return "\(s)s" }
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}

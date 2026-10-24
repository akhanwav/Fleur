// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WaysToWatchPicker.swift
//  Rivulet
//
//  "Ways to Watch" — every playable copy of an OWNED title across every
//  accessible Plex server (this account's own, and shared ones), not just
//  this server's own multi-version list. Built on the same tile-menu popup
//  as the single-server `VersionPicker`; this is its cross-server sibling.
//
//  Cross-server lookup reuses `OtherServersAvailabilityChecker`'s per-session
//  guid index (same expensive first-call full-library page, same session
//  cache) rather than building a second one.
//

import UIKit

/// Where a Ways to Watch row actually plays from.
enum WaysToWatchTarget {
    /// A version on the CURRENTLY SELECTED server — the existing
    /// single-server path (`MediaSource.id`).
    case local(mediaID: String)
    /// A copy on a DIFFERENT accessible server (owned or shared).
    case remote(serverURL: String, token: String, ratingKey: String, mediaID: String?)
}

enum WaysToWatchPicker {
    struct Row {
        let label: String
        let isDefault: Bool
        let target: WaysToWatchTarget
    }

    /// Every row for `item`: this server's own versions (ranked, best first)
    /// plus one best copy per OTHER server that has a match, each labeled
    /// with its server name. `includeOtherServers` is false when the host
    /// has no way to play a remote pick (`onPlayRemoteVersion` unset) — the
    /// picker then degrades to exactly `VersionPicker`'s old single-server
    /// behavior, never offering a choice it can't carry out.
    static func rows(for item: MediaItem, detail: MediaItemDetail, includeOtherServers: Bool) async -> [Row] {
        let localSources = VersionRanking.ordered(detail.mediaSources)
        guard !localSources.isEmpty else { return [] }

        let localName = await MainActor.run {
            PlexAuthManager.shared.selectedServer?.sourceTitle ?? PlexAuthManager.shared.selectedServer?.name
        } ?? "This Server"

        var rows: [Row] = zip(localSources, VersionPicker.labels(for: localSources)).enumerated().map { index, pair in
            let (source, label) = pair
            return Row(label: "\(localName) · \(label)", isDefault: index == 0, target: .local(mediaID: source.id))
        }

        guard includeOtherServers, item.ref.isPlex else { return localSources.count >= 2 ? rows : [] }

        let matchGuids = await guidsForMatching(item: item, detail: detail)
        guard !matchGuids.isEmpty else { return localSources.count >= 2 ? rows : [] }

        let copies = await OtherServersAvailabilityChecker.shared.copies(forGuids: matchGuids)
        for copy in copies {
            guard let remoteDetail = await remoteDetail(for: item, copy: copy) else { continue }
            let remoteSources = VersionRanking.ordered(remoteDetail.mediaSources)
            guard !remoteSources.isEmpty else { continue }
            let labels = VersionPicker.labels(for: remoteSources)
            rows += zip(remoteSources, labels).map { source, label in
                Row(label: "\(copy.serverName) · \(label)", isDefault: false,
                    target: .remote(serverURL: copy.serverURL, token: copy.token,
                                    ratingKey: remoteDetail.item.ref.itemID, mediaID: source.id))
            }
        }

        // One local version and no other-server copies found: nothing to
        // choose between, matching VersionPicker's own single-version gate.
        return rows.count >= 2 ? rows : []
    }

    static func present(_ rows: [Row], from host: UIViewController, sourceFrame: CGRect?,
                        onPick: @escaping (WaysToWatchTarget) -> Void) {
        guard rows.count >= 2 else { return }
        let actions = rows.map { row in
            TileMenuAction(title: row.isDefault ? "\(row.label) · Default" : row.label, systemImage: "play.fill") {
                onPick(row.target)
            }
        }
        let popup = TileMenuPopupViewController(sections: [actions], sourceFrame: sourceFrame,
                                                header: TileMenuHeader(title: "Ways to Watch"))
        host.topmostPresented.present(popup, animated: false)
    }

    /// Guids to search other servers by. A movie matches on its own guids;
    /// an episode has none of its own worth matching on (Plex rarely tags
    /// per-episode external ids), so it matches on the SHOW's guids and the
    /// specific episode is resolved afterward by season/episode number.
    private static func guidsForMatching(item: MediaItem, detail: MediaItemDetail) async -> [String] {
        let source: [String: String]
        if item.kind == .episode, let showRef = item.grandparentRef,
           let provider = await MainActor.run { MediaProviderRegistry.shared.provider(for: showRef.providerID) },
           let showDetail = try? await provider.fullDetail(for: showRef) {
            source = showDetail.externalIDs
        } else {
            source = detail.externalIDs
        }
        return source.compactMap { key, value in
            switch key {
            case "tmdb", "imdb", "tvdb": return "\(key)://\(value)"
            default: return nil
            }
        }
    }

    /// Full detail for `item` on `copy`'s server: the matched ratingKey
    /// directly for a movie; for an episode, the matched ratingKey is the
    /// SHOW, so its episode list is paged to find the one with the same
    /// season/episode numbers.
    private static func remoteDetail(for item: MediaItem,
                                     copy: OtherServersAvailabilityChecker.ServerCopy) async -> MediaItemDetail? {
        let network = PlexNetworkManager.shared
        var ratingKey = copy.ratingKey
        if item.kind == .episode, let season = item.seasonNumber, let episode = item.episodeNumber {
            guard let leaves = try? await network.getAllLeaves(
                serverURL: copy.serverURL, authToken: copy.token, ratingKey: copy.ratingKey
            ), let match = leaves.first(where: { $0.parentIndex == season && $0.index == episode }),
            let matchKey = match.ratingKey else { return nil }
            ratingKey = matchKey
        }
        guard let meta = try? await network.getFullMetadata(
            serverURL: copy.serverURL, authToken: copy.token, ratingKey: ratingKey
        ) else { return nil }
        // Never registered with MediaProviderRegistry — this detail is only
        // read locally for its ratingKey/mediaSources, so a provider id
        // scoped to the REMOTE server (not the selected one) just keeps
        // `.ref.isPlex` honest for a value that stays entirely in this file.
        return PlexMediaMapper.detail(meta, providerID: "plex:\(copy.machineId)",
                                      serverURL: copy.serverURL, authToken: copy.token)
    }
}

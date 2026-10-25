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
//  Other servers come from `OtherServersAvailabilityChecker`: one lookup of
//  the title's Plex guid per server, in parallel, each with a short timeout.
//  The button and its rows fill in when that answers; nothing waits on it.
//

import UIKit

/// Where a Ways to Watch row actually plays from.
nonisolated enum WaysToWatchTarget: Hashable, Sendable {
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

    /// This server's own versions of `item`, ranked, best first. One row is
    /// still a list worth showing: it is where the server, resolution,
    /// HDR/DV, bitrate, size and audio of the only copy are read. Synchronous,
    /// so the button can appear with the detail.
    static func localRows(for detail: MediaItemDetail) -> [Row] {
        let localSources = VersionRanking.ordered(detail.mediaSources)
        let localName = PlexAuthManager.shared.selectedServer?.sourceTitle
            ?? PlexAuthManager.shared.selectedServer?.name ?? "This Server"
        return zip(localSources, VersionPicker.labels(for: localSources)).enumerated().map { index, pair in
            let (source, label) = pair
            return Row(label: "\(localName) · \(label)", isDefault: index == 0, target: .local(mediaID: source.id))
        }
    }

    /// Every version on each OTHER server that holds `item`, labeled with
    /// its server name. Plex's own guid names the same title (movie, show or
    /// episode) on every server that matched it; an unmatched item has none.
    static func otherServerRows(for item: MediaItem, detail: MediaItemDetail) async -> [Row] {
        guard item.ref.isPlex, let plexGuid = detail.plexGuid else { return [] }
        let copies = await OtherServersAvailabilityChecker.shared.copies(plexGuid: plexGuid)
        return await withTaskGroup(of: (String, [Row]).self) { group in
            for copy in copies {
                group.addTask { (copy.serverName, await remoteRows(for: copy)) }
            }
            var byServer: [(String, [Row])] = []
            for await result in group { byServer.append(result) }
            return byServer.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    static func present(_ rows: [Row], from host: UIViewController, sourceFrame: CGRect?,
                        onPick: @escaping (WaysToWatchTarget) -> Void) {
        guard !rows.isEmpty else { return }
        let actions = rows.map { row in
            TileMenuAction(title: row.isDefault ? "\(row.label) · Default" : row.label, systemImage: "play.fill") {
                onPick(row.target)
            }
        }
        let popup = TileMenuPopupViewController(sections: [actions], sourceFrame: sourceFrame,
                                                header: TileMenuHeader(title: "Ways to Watch"))
        host.topmostPresented.present(popup, animated: false)
    }

    /// One row per version of `copy`, read from its own server.
    private static func remoteRows(for copy: OtherServersAvailabilityChecker.ServerCopy) async -> [Row] {
        guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
            serverURL: copy.serverURL, authToken: copy.token, ratingKey: copy.ratingKey
        ) else { return [] }
        // Never registered with MediaProviderRegistry — this detail is only
        // read locally for its mediaSources, so a provider id scoped to the
        // REMOTE server just keeps `.ref.isPlex` honest.
        let detail = PlexMediaMapper.detail(meta, providerID: "plex:\(copy.machineId)",
                                            serverURL: copy.serverURL, authToken: copy.token)
        let sources = VersionRanking.ordered(detail.mediaSources)
        return zip(sources, VersionPicker.labels(for: sources)).map { source, label in
            Row(label: "\(copy.serverName) · \(label)", isDefault: false,
                target: .remote(serverURL: copy.serverURL, token: copy.token,
                                ratingKey: copy.ratingKey, mediaID: source.id))
        }
    }
}

/// Plays a copy that lives on a server OTHER than the selected one: Ways to
/// Watch picks and the unowned detail's On Your Servers entries. A shared
/// library's progress is per server, so this reads THAT server's metadata
/// first and prompts from its own viewOffset, not the local item's.
enum RemoteCopyPlayer {
    @MainActor
    static func play(_ target: WaysToWatchTarget, from host: UIViewController) {
        guard case .remote(let serverURL, let token, let ratingKey, let mediaID) = target else { return }
        Task { @MainActor [weak host] in
            let network = PlexNetworkManager.shared
            guard var playItem = try? await network.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            // A show plays its next episode on that server: the one in
            // progress, else the first unwatched, else the first.
            if playItem.type == "show" {
                guard let leaves = try? await network.getAllLeaves(
                    serverURL: serverURL, authToken: token, ratingKey: ratingKey),
                    let next = leaves.first(where: \.isInProgress)
                        ?? leaves.first(where: { ($0.viewCount ?? 0) == 0 }) ?? leaves.first,
                    let nextKey = next.ratingKey,
                    let episode = try? await network.getFullMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: nextKey)
                else { return }
                playItem = episode
            }
            guard let host else { return }
            let resume = playItem.isInProgress ? playItem.viewOffset.map { Double($0) / 1000 } : nil
            ResumePrompt.resolve(offsetSeconds: resume ?? 0, from: host) { [weak host] startOver in
                guard let host else { return }
                let viewModel = UniversalPlayerViewModel(
                    metadata: playItem, serverURL: serverURL, authToken: token,
                    startOffset: startOver ? 0 : resume, preferredMediaID: mediaID)
                PlayerPresenter.present(viewModel: viewModel, from: host)
            }
        }
    }
}

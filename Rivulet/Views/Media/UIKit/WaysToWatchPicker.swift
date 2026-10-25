// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WaysToWatchPicker.swift
//  Rivulet
//
//  "Ways to Watch": a detail page is tied to ONE server's copy of its title.
//  `DetailCopySelection` holds every copy (the main server's, and each other
//  server's that the user has turned on in Settings → Servers), picks the one
//  the page opens on, and switches the page to another when the user picks
//  it from the Ways to Watch list. Picking never plays: the page's own Play
//  button plays the selected copy, with that server's resume prompt.
//
//  Other servers come from `OtherServersAvailabilityChecker`: one lookup of
//  the title's Plex guid per server, in parallel, each with a short timeout.
//  The main copy is there at once; the others join when they answer.
//

import UIKit

/// Where a play actually goes.
nonisolated enum WaysToWatchTarget: Hashable, Sendable {
    /// A version on the CURRENTLY SELECTED server (`MediaSource.id`).
    case local(mediaID: String)
    /// A copy on a DIFFERENT accessible server (owned or shared).
    case remote(serverURL: String, token: String, ratingKey: String, mediaID: String?)
}

/// One server's copy of the title a detail page shows.
struct DetailCopy {
    struct RemoteAccess: Hashable {
        let serverURL: String
        let token: String
        let ratingKey: String
    }

    let machineId: String
    let serverName: String
    let isMainServer: Bool
    /// That server's own view of the title: its watch state and resume point.
    var item: MediaItem
    /// That server's detail (its files, audio and subtitle tracks).
    var detail: MediaItemDetail?
    /// nil on the main server, whose copy plays through the page's own route.
    let remote: RemoteAccess?
    /// A show's next episode on this server (remote copies only; the main
    /// copy's comes from the page's own resolver).
    var playTarget: MediaItem?

    var sources: [MediaSource] { VersionRanking.ordered(detail?.mediaSources ?? []) }
}

@MainActor
final class DetailCopySelection {
    /// A server to open the next page for a title on, keyed by Plex guid or
    /// `"tmdb:<movie|tv>:<id>"`: set by a pick that opens a page (Continue
    /// Watching's menu), read once by that page.
    static var pendingServer: [String: String] = [:]

    private(set) var copies: [DetailCopy] = []
    private(set) var selectedIndex: Int?
    /// The picked version, or nil for the copy's best.
    private(set) var selectedMediaID: String?
    /// Fires when the copies or the selection change.
    var onChange: (() -> Void)?

    private var token: UInt64 = 0

    var selected: DetailCopy? { selectedIndex.flatMap { copies.indices.contains($0) ? copies[$0] : nil } }
    var isRemoteSelected: Bool { selected?.remote != nil }

    /// The selected copy's detail with the picked version first, so badges
    /// and the Info popup describe the file that will play.
    var selectedDetail: MediaItemDetail? {
        guard var detail = selected?.detail else { return nil }
        if let id = selectedMediaID, let index = detail.mediaSources.firstIndex(where: { $0.id == id }) {
            detail.mediaSources.insert(detail.mediaSources.remove(at: index), at: 0)
        }
        return detail
    }

    func reset() {
        token &+= 1
        copies = []
        selectedIndex = nil
        selectedMediaID = nil
    }

    /// Start from the main server's copy (when the title is on it), then add
    /// every other server's and settle on the default: a pending pick, else
    /// the server it was last watched on, else the first in the user's order.
    func load(item: MediaItem, mainDetail: MediaItemDetail?) {
        reset()
        let current = token
        let main = ServerPreferences.mainMachineId
            ?? PlexAuthManager.shared.selectedServer?.machineIdentifier ?? "main"
        if !item.isMetadataOnly {
            let name = item.ref.isPlex
                ? (PlexAuthManager.shared.selectedServer?.sourceTitle ?? PlexAuthManager.shared.selectedServer?.name)
                : nil
            copies = [DetailCopy(machineId: main, serverName: name ?? "This Server", isMainServer: true,
                                 item: item, detail: mainDetail, remote: nil)]
            selectedIndex = 0
            onChange?()
        }
        guard item.ref.isPlex || item.isMetadataOnly else { return }

        Task { @MainActor [weak self] in
            let (guid, tmdbKey, remote) = await Self.otherCopies(of: item, mainDetail: mainDetail)
            guard let guid, let self, self.token == current else { return }
            let all = ServerPreferences.sorted(self.copies.filter(\.isMainServer) + remote, by: \.machineId)
            let pending = Self.pendingServer.removeValue(forKey: guid)
                ?? tmdbKey.flatMap { Self.pendingServer.removeValue(forKey: $0) }
            let preferred = [pending, ServerPreferences.lastWatchedServer(forGuid: guid)].compactMap { $0 }
            let index = preferred.lazy.compactMap { id in all.firstIndex { $0.machineId == id } }.first
            self.copies = all
            self.selectedIndex = all.isEmpty ? nil : (index ?? 0)
            self.selectedMediaID = nil
            self.onChange?()
        }
    }

    /// Every OTHER server's copy of `item`, read from each server, with the
    /// Plex guid it was found by (and the TMDB key for an unowned title).
    static func otherCopies(of item: MediaItem, mainDetail: MediaItemDetail?) async
        -> (guid: String?, tmdbKey: String?, copies: [DetailCopy]) {
        let checker = OtherServersAvailabilityChecker.shared
        var guid = mainDetail?.plexGuid
        var tmdbKey: String?
        if item.isMetadataOnly, let (tmdbId, type) = TMDBMediaMapper.decodeItemID(item.ref.itemID) {
            tmdbKey = "tmdb:\(type.rawValue):\(tmdbId)"
            guid = await checker.plexGuid(forTmdbId: tmdbId, type: type)
        }
        guard let guid else { return (nil, tmdbKey, []) }
        let found = await checker.copies(plexGuid: guid)
        let copies = await withTaskGroup(of: DetailCopy?.self) { group in
            for copy in found { group.addTask { await remoteCopy(copy) } }
            var copies: [DetailCopy] = []
            for await copy in group { if let copy { copies.append(copy) } }
            return copies
        }
        return (guid, tmdbKey, copies)
    }

    /// Point the page at another copy (and optionally one of its versions).
    func select(machineId: String, mediaID: String? = nil) {
        guard let index = copies.firstIndex(where: { $0.machineId == machineId }) else { return }
        selectedIndex = index
        selectedMediaID = mediaID
        onChange?()
    }

    /// Ways to Watch: every copy's versions, the selected one checked, each
    /// row naming its server and that server's own resume time. Picking a
    /// row switches the page to it.
    func present(from host: UIViewController, sourceFrame: CGRect?) {
        var actions: [TileMenuAction] = []
        for (index, copy) in copies.enumerated() {
            let resume = Self.resumeText(copy.playTarget ?? copy.item)
            let sources = copy.sources
            if sources.isEmpty || copy.item.kind == .show || copy.item.kind == .season {
                // A show has no file of its own: one row per server.
                let next = copy.playTarget.map { EpisodePicker.playTitle(for: $0, on: .show) }
                let label = [copy.serverName, next ?? resume].compactMap { $0 }.joined(separator: " · ")
                actions.append(row(label, selected: index == selectedIndex, machineId: copy.machineId, mediaID: nil))
                continue
            }
            for (sourceIndex, (source, label)) in zip(sources, VersionPicker.labels(for: sources)).enumerated() {
                let isSelected = index == selectedIndex
                    && (selectedMediaID.map { $0 == source.id } ?? (sourceIndex == 0))
                let text = [copy.serverName, label, resume].compactMap { $0 }.joined(separator: " · ")
                actions.append(row(text, selected: isSelected, machineId: copy.machineId, mediaID: source.id))
            }
        }
        guard !actions.isEmpty else { return }
        let popup = TileMenuPopupViewController(sections: [actions], sourceFrame: sourceFrame,
                                                header: TileMenuHeader(title: "Ways to Watch"))
        host.topmostPresented.present(popup, animated: false)
    }

    private func row(_ title: String, selected: Bool, machineId: String, mediaID: String?) -> TileMenuAction {
        TileMenuAction(title: title, systemImage: selected ? "checkmark.circle.fill" : "circle") { [weak self] in
            self?.select(machineId: machineId, mediaID: mediaID)
        }
    }

    /// Play the selected copy when it is on another server. The main
    /// server's copy plays through the page's own route instead.
    func playRemote(from host: UIViewController) {
        guard let copy = selected, let remote = copy.remote else { return }
        let ratingKey = copy.playTarget?.ref.itemID ?? remote.ratingKey
        RemoteCopyPlayer.play(.remote(serverURL: remote.serverURL, token: remote.token,
                                      ratingKey: ratingKey, mediaID: selectedMediaID),
                              machineId: copy.machineId, from: host)
    }

    /// "Resume 42:10" when that server holds a resume point.
    static func resumeText(_ item: MediaItem) -> String? {
        guard item.isInProgress else { return nil }
        return "Resume \(PlexMetadata.formatResumeTime(Int(item.userState.viewOffset * 1000)))"
    }

    private static func remoteCopy(_ copy: OtherServersAvailabilityChecker.ServerCopy) async -> DetailCopy? {
        let network = PlexNetworkManager.shared
        guard let meta = try? await network.getFullMetadata(
            serverURL: copy.serverURL, authToken: copy.token, ratingKey: copy.ratingKey) else { return nil }
        // Never registered with MediaProviderRegistry: a provider id scoped
        // to the remote server just keeps `.ref.isPlex` honest.
        let providerID = "plex:\(copy.machineId)"
        var detailCopy = DetailCopy(
            machineId: copy.machineId, serverName: copy.serverName, isMainServer: false,
            item: PlexMediaMapper.item(meta, providerID: providerID, serverURL: copy.serverURL, authToken: copy.token),
            detail: PlexMediaMapper.detail(meta, providerID: providerID, serverURL: copy.serverURL, authToken: copy.token),
            remote: .init(serverURL: copy.serverURL, token: copy.token, ratingKey: copy.ratingKey))
        if meta.type == "show", let next = await RemoteCopyPlayer.nextEpisode(
            serverURL: copy.serverURL, token: copy.token, showRatingKey: copy.ratingKey) {
            detailCopy.playTarget = PlexMediaMapper.item(next, providerID: providerID,
                                                         serverURL: copy.serverURL, authToken: copy.token)
        }
        return detailCopy
    }
}

/// Plays a copy that lives on a server OTHER than the selected one. A shared
/// library's progress is per server, so this reads THAT server's metadata
/// first and prompts from its own viewOffset, not the local item's, and the
/// player reports progress back to that server only.
enum RemoteCopyPlayer {
    @MainActor
    static func play(_ target: WaysToWatchTarget, machineId: String, from host: UIViewController) {
        guard case .remote(let serverURL, let token, let ratingKey, let mediaID) = target else { return }
        Task { @MainActor [weak host] in
            let network = PlexNetworkManager.shared
            guard var playItem = try? await network.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            if playItem.type == "show" {
                guard let next = await nextEpisode(serverURL: serverURL, token: token, showRatingKey: ratingKey),
                      let nextKey = next.ratingKey,
                      let episode = try? await network.getFullMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: nextKey)
                else { return }
                playItem = episode
            }
            guard let host else { return }
            let resume = playItem.isInProgress ? playItem.viewOffset.map { Double($0) / 1000 } : nil
            let item = playItem
            ResumePrompt.resolve(offsetSeconds: resume ?? 0, from: host) { [weak host] startOver in
                guard let host else { return }
                ServerPreferences.recordWatched(guids: [item.guid, item.grandparentGuid], machineId: machineId)
                let viewModel = UniversalPlayerViewModel(
                    metadata: item, serverURL: serverURL, authToken: token,
                    startOffset: startOver ? 0 : resume, preferredMediaID: mediaID)
                PlayerPresenter.present(viewModel: viewModel, from: host)
            }
        }
    }

    /// A show's next episode on that server: the one in progress, else the
    /// first unwatched, else the first.
    static func nextEpisode(serverURL: String, token: String, showRatingKey: String) async -> PlexMetadata? {
        guard let leaves = try? await PlexNetworkManager.shared.getAllLeaves(
            serverURL: serverURL, authToken: token, ratingKey: showRatingKey) else { return nil }
        return leaves.first(where: \.isInProgress)
            ?? leaves.first(where: { ($0.viewCount ?? 0) == 0 }) ?? leaves.first
    }
}

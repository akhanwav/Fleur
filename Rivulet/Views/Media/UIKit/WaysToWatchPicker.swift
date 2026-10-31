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
import os.log

private let copiesLog = Logger(subsystem: "com.rivulet.app", category: "WaysToWatch")

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

    var machineId: String
    let serverName: String
    /// The page's own item (on the main server), which plays through the
    /// page's own route. Another library's copy on the main server is not.
    let isMainServer: Bool
    /// That server's own view of the title: its watch state and resume point.
    var item: MediaItem
    /// That server's detail (its files, audio and subtitle tracks).
    var detail: MediaItemDetail?
    /// nil on the main server, whose copy plays through the page's own route.
    let remote: RemoteAccess?
    /// A show's or season's episode that Play would start on this server,
    /// and that episode's detail (its files: the quality a row shows).
    var playTarget: MediaItem?
    var playTargetDetail: MediaItemDetail?

    /// Whether this copy is a show or season (rows describe its next episode).
    var isSeries: Bool { item.kind == .show || item.kind == .season }

    var sources: [MediaSource] { VersionRanking.ordered(detail?.mediaSources ?? []) }
    /// A server can hold the title in several libraries: a copy is a server
    /// and an item.
    var id: String { "\(machineId):\(remote?.ratingKey ?? item.ref.itemID)" }
}

@MainActor
final class DetailCopySelection {
    /// The copy a tile was switched to (Ways to Watch on a tile), keyed by
    /// Plex guid or `"tmdb:<movie|tv>:<id>"`. A page for that title opens on
    /// it, before its own lookup answers and whether or not that lookup finds
    /// it again (a slow server can time out), and every later load of the
    /// page does the same: it is read, never consumed. The tile clears it.
    static var pendingServer: [String: DetailCopy] = [:]

    /// Items whose page opens on exactly their own copy, whatever was picked
    /// or last watched elsewhere: a Continue Watching card names the copy it
    /// resumes (its tag is that copy's quality), so its page must not land on
    /// another library's or server's. Server switching stays on the page.
    static var pinnedToOwnCopy: Set<MediaItemRef> = []

    /// The pending pick for a page's title, from what the page knows now.
    static func pendingCopy(for item: MediaItem, mainDetail: MediaItemDetail?) -> DetailCopy? {
        if let guid = mainDetail?.plexGuid, let copy = pendingServer[guid] { return copy }
        guard let (tmdbId, type) = TMDBMediaMapper.decodeItemID(item.ref.itemID) else { return nil }
        return pendingServer["tmdb:\(type.rawValue):\(tmdbId)"]
    }

    private(set) var copies: [DetailCopy] = []
    /// True once the other servers have answered (with or without a copy):
    /// an unowned page then shows Ways to Watch either way.
    private(set) var hasLookedUp = false
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

    // MARK: Cuts

    /// Every file of every copy of a movie, for `MovieCuts`; empty for a show.
    var cutVersions: [MovieCuts.Version] {
        copies.filter { $0.item.kind == .movie }.flatMap { copy in
            copy.sources.map { MovieCuts.Version(copyID: copy.id, edition: Self.edition(of: copy), source: $0) }
        }
    }

    /// The file the page would play: the picked version, else the copy's best.
    var selectedCutVersion: MovieCuts.Version? {
        guard let copy = selected, copy.item.kind == .movie,
              let source = selectedDetail?.mediaSources.first else { return nil }
        return MovieCuts.Version(copyID: copy.id, edition: Self.edition(of: copy), source: source)
    }

    /// The selected file's length when the movie's copies are different cuts.
    var selectedCutRuntime: TimeInterval? { MovieCuts.runtime(of: selectedCutVersion, among: cutVersions) }

    /// The selected cut's name ("Extended Edition"), for the info boxes.
    var selectedCutName: String? {
        selectedCutVersion.flatMap { MovieCuts.name(of: $0, among: cutVersions) }
    }

    private static func edition(of copy: DetailCopy) -> String? {
        copy.detail?.item.editionTitle ?? copy.item.editionTitle
    }

    func reset() {
        token &+= 1
        hasLookedUp = false
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
        let main = PlexItemServer.machineId(for: item.ref) ?? "main"
        let pinned = Self.pinnedToOwnCopy.contains(item.ref)
        if !item.isMetadataOnly {
            let name = PlexItemServer.name(for: item.ref)
            copies = [DetailCopy(machineId: main, serverName: name ?? "This Server", isMainServer: true,
                                 item: item, detail: mainDetail, remote: nil)]
            selectedIndex = 0
            if !pinned, let pending = Self.pendingCopy(for: item, mainDetail: mainDetail), !pending.isMainServer,
               pending.id != copies[0].id {
                copies.append(pending)
                selectedIndex = 1
            }
            onChange?()
            if item.kind == .show || item.kind == .season {
                Task { @MainActor [weak self] in
                    guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                          let target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider)
                    else { return }
                    let detail = try? await provider.fullDetail(for: target.ref)
                    guard let self, self.token == current,
                          let index = self.copies.firstIndex(where: \.isMainServer) else { return }
                    self.copies[index].playTarget = target
                    self.copies[index].playTargetDetail = detail
                    self.onChange?()
                }
            }
        }
        guard item.ref.isPlex || item.isMetadataOnly else { return }

        Task { @MainActor [weak self] in
            let (guid, tmdbKey, remote) = await Self.otherCopies(of: item, mainDetail: mainDetail)
            copiesLog.info("[Copies] \(item.title, privacy: .public): guid \(guid ?? "none", privacy: .public), \(remote.count, privacy: .public) server copies")
            guard let self, self.token == current else { return }
            self.hasLookedUp = true
            guard let guid else { self.onChange?(); return }
            // `self.copies`, not a fresh copy: the main copy may already hold
            // its resolved Play target.
            var own = self.copies.filter(\.isMainServer)
            // The lookup searches the page's own server too, so it finds the
            // page's own item again: list that one once, as the page's.
            if let mainId = PlexItemServer.machineId(for: item.ref) {
                for index in own.indices { own[index].machineId = mainId }
            }
            let ownIDs = Set(own.map(\.id))
            var found = remote.filter { !ownIDs.contains($0.id) }
            let pendingCopy = pinned ? nil : Self.pendingServer[guid] ?? tmdbKey.flatMap { Self.pendingServer[$0] }
            // The tile's pick wins even when this lookup missed its server.
            if let pendingCopy, !ownIDs.contains(pendingCopy.id), !found.contains(where: { $0.id == pendingCopy.id }) {
                found.append(pendingCopy)
            }
            let all = Self.ordered(own + found)
            let preferred = pinned
                ? own.map(\.id)
                : [pendingCopy?.id, ServerPreferences.lastWatchedServer(forGuid: guid)].compactMap { $0 }
            // A pending pick names a copy; last watched names a server. On
            // that server the page's own copy comes first: the server's best
            // copy is another library's file (a 1080p tile opened the 4K DV
            // copy beside it).
            let index = preferred.lazy.compactMap { id in
                all.firstIndex { $0.id == id }
                    ?? all.firstIndex { $0.machineId == id && ownIDs.contains($0.id) }
                    ?? all.firstIndex { $0.machineId == id }
            }.first
            // No pending pick and never watched: the first server in the
            // Settings order, its best copy first (`ordered`).
            self.copies = all
            self.selectedIndex = all.isEmpty ? nil : (index ?? 0)
            self.selectedMediaID = nil
            self.onChange?()
        }
    }

    /// The main server's machine id, also when `selectedServer` is nil
    /// after a relaunch (the lookup stores it once it resolves servers).
    static var mainMachineId: String? {
        ServerPreferences.mainMachineId ?? PlexAuthManager.shared.selectedServer?.machineIdentifier
    }

    /// Server order from Settings, then best quality first within a server.
    static func ordered(_ copies: [DetailCopy]) -> [DetailCopy] {
        let ranking = VersionRanking.ordered(copies.flatMap(\.sources)).map(\.id)
        func best(_ copy: DetailCopy) -> Int {
            copy.sources.compactMap { ranking.firstIndex(of: $0.id) }.min() ?? Int.max
        }
        let byQuality = copies.sorted { best($0) < best($1) }
        return ServerPreferences.sorted(byQuality, by: \.machineId)
    }

    /// Every OTHER server's copy of `item`, read from each server, with the
    /// Plex guid it was found by (and the TMDB key for an unowned title).
    /// `onCopy` gets each copy as its server answers, before the rest, and
    /// `onServerDone` each server's machine id once all its copies are in
    /// (none, for a server without the title).
    static func otherCopies(of item: MediaItem, mainDetail: MediaItemDetail?,
                            onGuid: (@MainActor @Sendable (String?) -> Void)? = nil,
                            onCopy: (@MainActor @Sendable (DetailCopy) -> Void)? = nil,
                            onServerDone: (@MainActor @Sendable (String) -> Void)? = nil) async
        -> (guid: String?, tmdbKey: String?, copies: [DetailCopy]) {
        let checker = OtherServersAvailabilityChecker.shared
        var guid = mainDetail?.plexGuid
        var tmdbKey: String?
        if item.isMetadataOnly, let (tmdbId, type) = TMDBMediaMapper.decodeItemID(item.ref.itemID) {
            tmdbKey = "tmdb:\(type.rawValue):\(tmdbId)"
            guid = await checker.plexGuid(forTmdbId: tmdbId, type: type)
        } else if guid == nil, item.kind == .movie || item.kind == .show,
                  let tmdbId = mainDetail?.externalIDs["tmdb"].flatMap(Int.init) {
            // An owned item without Plex's own guid (a legacy agent): its
            // TMDB id still names the title on the other servers.
            guid = await checker.plexGuid(forTmdbId: tmdbId, type: item.kind == .movie ? .movie : .tv)
        }
        await onGuid?(guid)
        guard let guid else { return (nil, tmdbKey, []) }
        let copies = await checker.copies(plexGuid: guid) { machineId, found in
            let copies = await withTaskGroup(of: DetailCopy?.self) { group in
                for copy in found { group.addTask { await remoteCopy(copy) } }
                var copies: [DetailCopy] = []
                for await copy in group {
                    guard let copy else { continue }
                    copies.append(copy)
                    await onCopy?(copy)
                }
                return copies
            }
            await onServerDone?(machineId)
            return copies
        }
        return (guid, tmdbKey, copies)
    }

    /// Point the page at a copy (by `DetailCopy.id`, or the best copy on a
    /// server by its machine id), and optionally one of its versions.
    func select(copyID: String, mediaID: String? = nil) {
        guard let index = copies.firstIndex(where: { $0.id == copyID })
                ?? copies.firstIndex(where: { $0.machineId == copyID }) else { return }
        selectedIndex = index
        selectedMediaID = mediaID
        onChange?()
    }

    /// Ways to Watch: every copy's versions, the selected one checked, each
    /// row naming its server and that server's own resume time. Picking a
    /// row switches the page to it.
    func present(from host: UIViewController, sourceFrame: CGRect?) {
        var actions: [TileMenuAction] = []
        let cuts = cutVersions
        for (index, copy) in copies.enumerated() {
            let resume = Self.resumeText(copy.item)
            let sources = copy.sources
            if sources.isEmpty || copy.isSeries {
                // A show has no file of its own: one row per server, about
                // the episode Play would start there.
                let label = ([copy.serverName] + Self.seriesSummary(copy)).joined(separator: " · ")
                actions.append(row(label, selected: index == selectedIndex, copyID: copy.id, mediaID: nil))
                continue
            }
            let cutLabels = sources.map { source in
                MovieCuts.label(of: MovieCuts.Version(copyID: copy.id, edition: Self.edition(of: copy), source: source),
                                among: cuts)
            }
            let labels = VersionPicker.labels(for: sources, cuts: cutLabels)
            for (sourceIndex, (source, label)) in zip(sources, labels).enumerated() {
                let isSelected = index == selectedIndex
                    && (selectedMediaID.map { $0 == source.id } ?? (sourceIndex == 0))
                let text = [copy.serverName, label, resume].compactMap { $0 }.joined(separator: " · ")
                actions.append(row(text, selected: isSelected, copyID: copy.id, mediaID: source.id))
            }
        }
        if actions.isEmpty {
            // An unowned title no server holds: say so, rather than no list.
            actions = [TileMenuAction(title: "Not on your servers", systemImage: "xmark.circle") {}]
        }
        let popup = TileMenuPopupViewController(sections: [actions], sourceFrame: sourceFrame,
                                                header: TileMenuHeader(title: "Ways to Watch"))
        host.topmostPresented.present(popup, animated: false)
    }

    private func row(_ title: String, selected: Bool, copyID: String, mediaID: String?) -> TileMenuAction {
        TileMenuAction(title: title, systemImage: selected ? "checkmark.circle.fill" : "circle") { [weak self] in
            self?.select(copyID: copyID, mediaID: mediaID)
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

    /// What a show's or season's copy offers on its server, the same in Ways
    /// to Watch and On Your Servers, wherever the page was opened from: the
    /// episode Play would start, as its Play button names it ("Play S2 · E3",
    /// "Resume S2 · E3 · 12 min left"), the
    /// watched count ("3 of 10 watched", or "10 episodes"), and that
    /// episode's file in full ("4K · DV · 18.4 Mbps · HEVC · EAC3 5.1 · 3.1 GB").
    static func seriesSummary(_ copy: DetailCopy) -> [String] {
        var parts: [String] = []
        if let target = copy.playTarget, target.kind == .episode {
            parts.append(EpisodePicker.playTitle(for: target))
        }
        if let progress = copy.detail?.item.childProgress ?? copy.item.childProgress, progress.total > 0 {
            parts.append(progress.played > 0
                ? "\(progress.played) of \(progress.total) watched"
                : (progress.total == 1 ? "1 episode" : "\(progress.total) episodes"))
        }
        // That episode's file in full, as a movie's row shows its own.
        if let source = VersionRanking.ordered(copy.playTargetDetail?.mediaSources ?? []).first {
            parts.append(VersionPicker.rowLabel(source))
        }
        return parts
    }

    /// The card / row line for any copy, the same in every Ways to Watch: a
    /// series' summary, else Play's label on that server ("Resume · 42 min
    /// left", "Play S2 · E5", "Play") and the best file in full.
    static func summary(_ copy: DetailCopy) -> String? {
        let parts = copy.isSeries
            ? seriesSummary(copy)
            : [EpisodePicker.playTitle(for: copy.item), copy.sources.first.map(VersionPicker.rowLabel)]
                .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "4K DV", "1080p HDR", "1080p".
    static func qualityText(_ source: MediaSource?) -> String? {
        guard let source else { return nil }
        let text = [source.resolutionBadge, source.rangeBadge].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// The Play button's title when that server holds a resume point:
    /// "Resume · 42 min left", "Resume S5 · E3 · 12 min left".
    static func resumeText(_ item: MediaItem) -> String? {
        guard item.isInProgress else { return nil }
        return EpisodePicker.playTitle(for: item)
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
        // A show or season: the episode Play would start on that server, read
        // in full so its row can name its quality.
        if meta.type == "show" || meta.type == "season",
           let next = await RemoteCopyPlayer.nextEpisode(
            serverURL: copy.serverURL, token: copy.token, showRatingKey: copy.ratingKey) {
            let episode = (try? await network.getFullMetadata(
                serverURL: copy.serverURL, authToken: copy.token, ratingKey: next.ratingKey ?? "")) ?? next
            detailCopy.playTarget = PlexMediaMapper.item(episode, providerID: providerID,
                                                         serverURL: copy.serverURL, authToken: copy.token)
            detailCopy.playTargetDetail = PlexMediaMapper.detail(episode, providerID: providerID,
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

    /// A show's (or season's) next episode on that server: the one in
    /// progress, else the first unwatched, else the first.
    static func nextEpisode(serverURL: String, token: String, showRatingKey: String) async -> PlexMetadata? {
        guard let leaves = try? await PlexNetworkManager.shared.getAllLeaves(
            serverURL: serverURL, authToken: token, ratingKey: showRatingKey) else { return nil }
        let index = EpisodePicker.nextUpIndex(inProgress: leaves.map(\.isInProgress),
                                              played: leaves.map { ($0.viewCount ?? 0) > 0 })
        return index.map { leaves[$0] }
    }
}

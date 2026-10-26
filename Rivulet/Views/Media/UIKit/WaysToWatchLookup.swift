// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WaysToWatchLookup.swift
//  Rivulet
//
//  One title's copies across servers for a tile's Ways to Watch, gathered in
//  the background and kept for the session. The popup opens on whatever is
//  known (this server's copy, at least) and fills in as each server answers,
//  so the slowest server never decides when it appears. A focused tile starts
//  its lookup early, so the popup is usually complete when it opens.
//
//  The session cache drops everything on `.plexDataNeedsRefresh`: a resume
//  point or watched flag changed somewhere, and every row's label reads them.
//

import Foundation

@MainActor
final class WaysToWatchLookup {
    private static var cache: [MediaItemRef: WaysToWatchLookup] = [:]
    private static var invalidation: NSObjectProtocol?

    /// The lookup for `item`, started now unless one is cached or running.
    static func lookup(for item: MediaItem) -> WaysToWatchLookup {
        if invalidation == nil {
            invalidation = NotificationCenter.default.addObserver(
                forName: .plexDataNeedsRefresh, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { cache.removeAll() } }
        }
        if let cached = cache[item.ref] { return cached }
        let lookup = WaysToWatchLookup(item: item)
        cache[item.ref] = lookup
        lookup.start()
        return lookup
    }

    /// `item`'s lookup if one is cached or running, without starting one.
    static func existing(for item: MediaItem) -> WaysToWatchLookup? { cache[item.ref] }

    /// Start `item`'s lookup ahead of a long press.
    static func prefetch(_ item: MediaItem) {
        guard offersWaysToWatch(item) else { return }
        _ = lookup(for: item)
    }

    /// A Plex item, or a title known only by its TMDB id (a Watchlist or
    /// Discover tile), which every server is asked for.
    static func offersWaysToWatch(_ item: MediaItem) -> Bool {
        (item.ref.isPlex || item.isMetadataOnly) && (item.kind == .movie || item.kind == .show || item.kind == .episode)
    }

    /// False for a title known only by its TMDB id: no copy of its own, and
    /// the main server is asked like any other.
    var hasOwnCopy: Bool { !item.isMetadataOnly }

    let item: MediaItem
    /// This server's copy: the tile's own item, its detail once it loads.
    private(set) var own: DetailCopy
    private(set) var others: [DetailCopy] = []
    private(set) var guid: String?
    /// Every server has answered, or timed out.
    private(set) var isFinished = false
    private var observers: [UUID: () -> Void] = [:]
    /// The other enabled servers, in Settings' order, fixed when the lookup
    /// starts so rows never trade places as servers answer.
    private let otherServers: [ServerPreferences.KnownServer]
    /// Those that have not answered yet.
    private var pending: Set<String>

    private init(item: MediaItem) {
        self.item = item
        let main = DetailCopySelection.mainMachineId ?? "main"
        own = DetailCopy(machineId: main,
                         serverName: PlexAuthManager.shared.mainServerName ?? "This Server",
                         isMainServer: true, item: item, detail: nil, remote: nil)
        let ownless = item.isMetadataOnly
        otherServers = ServerPreferences.knownServers.filter {
            ($0.machineId != main || ownless) && ServerPreferences.isEnabled($0.machineId)
        }
        pending = Set(otherServers.map(\.machineId))
    }

    /// One popup row: a copy, or a server still being asked.
    enum Entry {
        case copy(DetailCopy)
        case checking(serverName: String, machineId: String)
    }

    /// The rows in a fixed order: this server's copies, then each other
    /// server's in Settings' order, a server still being asked holding its
    /// place with one `checking` row. A server that answers fills that place;
    /// one without the title gives it up. Copies from a server the app did not
    /// know of yet come last.
    var entries: [Entry] {
        let own = ownCopy
        let all = (hasOwnCopy ? [own] : []) + others.filter { $0.id != own.id }
        var placed = Set<String>()
        var entries: [Entry] = []
        func add(server machineId: String) {
            let copies = DetailCopySelection.ordered(all.filter { $0.machineId == machineId })
            entries += copies.map(Entry.copy)
            placed.insert(machineId)
        }
        if hasOwnCopy { add(server: own.machineId) }
        for server in otherServers where !placed.contains(server.machineId) {
            if pending.contains(server.machineId) {
                entries.append(.checking(serverName: server.name, machineId: server.machineId))
                placed.insert(server.machineId)
            } else {
                add(server: server.machineId)
            }
        }
        let rest = all.filter { !placed.contains($0.machineId) }
        entries += DetailCopySelection.ordered(rest).map(Entry.copy)
        return entries
    }

    /// This server's copy under the main server's machine id, which may
    /// have resolved after the lookup began.
    var ownCopy: DetailCopy {
        var copy = own
        if let main = DetailCopySelection.mainMachineId { copy.machineId = main }
        return copy
    }

    /// `handler` runs on every change until `stopObserving`.
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    private func changed() { observers.values.forEach { $0() } }

    private func start() {
        let item = item
        if item.isMetadataOnly {
            Task { [weak self] in await self?.askServers(mainDetail: nil) }
            return
        }
        Task { [weak self] in
            guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                  let detail = try? await provider.fullDetail(for: item.ref) else {
                self?.fail()
                return
            }
            guard let self else { return }
            self.own.detail = detail
            self.changed()
            if item.kind == .show { self.resolveOwnEpisode(provider: provider) }
            await self.askServers(mainDetail: detail)
        }
    }

    /// Every server, each copy kept as it comes and shown with its server's
    /// answer. The guid comes from the page's own detail, or for a title
    /// known only by its TMDB id, from Plex's match for that id.
    private func askServers(mainDetail: MediaItemDetail?) async {
        _ = await DetailCopySelection.otherCopies(
            of: item, mainDetail: mainDetail,
            onGuid: { [weak self] guid in self?.guid = guid },
            onCopy: { [weak self] copy in self?.others.append(copy) },
            onServerDone: { [weak self] machineId in
                self?.pending.remove(machineId)
                self?.changed()
            })
        pending.removeAll()
        isFinished = true
        changed()
    }

    /// A show's copy names the episode Play would start, with its quality.
    private func resolveOwnEpisode(provider: any MediaProvider) {
        let item = item
        Task { [weak self] in
            guard let target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) else { return }
            let detail = try? await provider.fullDetail(for: target.ref)
            guard let self else { return }
            self.own.playTarget = target
            self.own.playTargetDetail = detail
            self.changed()
        }
    }

    /// Not cached: the next long press asks again.
    private func fail() {
        if Self.cache[item.ref] === self { Self.cache[item.ref] = nil }
        pending.removeAll()
        isFinished = true
        changed()
    }
}

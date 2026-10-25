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

    /// Start `item`'s lookup ahead of a long press.
    static func prefetch(_ item: MediaItem) {
        guard offersWaysToWatch(item) else { return }
        _ = lookup(for: item)
    }

    static func offersWaysToWatch(_ item: MediaItem) -> Bool {
        item.ref.isPlex && (item.kind == .movie || item.kind == .show || item.kind == .episode)
    }

    let item: MediaItem
    /// This server's copy: the tile's own item, its detail once it loads.
    private(set) var own: DetailCopy
    private(set) var others: [DetailCopy] = []
    private(set) var guid: String?
    /// Every server has answered, or timed out.
    private(set) var isFinished = false
    private var observers: [UUID: () -> Void] = [:]

    private init(item: MediaItem) {
        self.item = item
        own = DetailCopy(machineId: DetailCopySelection.mainMachineId ?? "main",
                         serverName: PlexAuthManager.shared.mainServerName ?? "This Server",
                         isMainServer: true, item: item, detail: nil, remote: nil)
    }

    /// Every copy in Settings' server order, this server's listed once: the
    /// lookup searches the main server too and finds the tile's item again.
    var copies: [DetailCopy] {
        let own = ownCopy
        return DetailCopySelection.ordered([own] + others.filter { $0.id != own.id })
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
            _ = await DetailCopySelection.otherCopies(
                of: item, mainDetail: detail,
                onGuid: { [weak self] guid in self?.guid = guid },
                onCopy: { [weak self] copy in
                    self?.others.append(copy)
                    self?.changed()
                })
            self.isFinished = true
            self.changed()
        }
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
        isFinished = true
        changed()
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CrossServerHistory.swift
//  Rivulet
//
//  Which server each show in Continue Watching was watched on most recently.
//
//  Every server keeps its own progress, and the row shows a show only from the
//  server it was last watched on: that server's own resume point or next-up
//  episode, one card per quality (`PlexDataStore.mergeContinueWatching`).
//  Another server's place stays on the show page, in Ways to Watch.
//
//  A next-up episode carries no watch time of its own, so the hub cannot say
//  which server was used last. Each server is asked for its show: its recently
//  watched shows (`/library/all?type=2&sort=lastViewedAt:desc`, one small
//  request), else a lookup by the show's guid. Nothing is combined: a server's
//  answer only places its own cards.
//
//  Runs when the shows in Continue Watching change, and at most every 15
//  minutes otherwise. The account's own profile only, like every feature that
//  reaches other servers (`OtherServersAvailabilityChecker.lookupServers`).
//

import Foundation

@MainActor
final class CrossServerHistory {

    /// A server's Continue Watching entries, as the row names the server.
    struct Source {
        let access: OtherServersAvailabilityChecker.ServerAccess
        let providerID: String
        let metas: [PlexMetadata]
    }

    /// Show guid → the provider id of the server it was last watched on, for
    /// shows in more than one server's library. Empty until the first pass ends.
    private(set) var lastWatched: [String: String] = [:]
    /// Called on the main actor when `lastWatched` changed.
    var onChange: (() -> Void)?

    static let interval: TimeInterval = 15 * 60
    private static let recentShowCount = 20
    private static let maxShows = 30
    private static let timeout: TimeInterval = 8

    private var task: Task<Void, Never>?
    private var lastRun: Date?
    private var lastSignature: String?

    /// Run a pass when the shows in Continue Watching changed, or the last
    /// pass is older than `interval`.
    func refresh(sources: [Source], now: Date = Date()) {
        guard task == nil else { return }
        guard sources.count > 1 else {
            if !lastWatched.isEmpty { lastWatched = [:]; onChange?() }
            return
        }
        let signature = Self.signature(sources)
        if signature == lastSignature, let lastRun, now.timeIntervalSince(lastRun) < Self.interval { return }
        lastSignature = signature
        lastRun = now
        // Its requests wait out the background (`ForegroundGate`).
        task = ForegroundGate.$holdsInBackground.withValue(true) {
            Task { [weak self] in
                guard let self else { return }
                let next = await Self.run(sources: sources)
                guard !Task.isCancelled else { return }
                self.task = nil
                guard next != self.lastWatched else { return }
                self.lastWatched = next
                self.onChange?()
            }
        }
    }

    /// Sign-out or a profile switch: nothing carries over.
    func reset() {
        task?.cancel()
        task = nil
        lastWatched = [:]
        lastRun = nil
        lastSignature = nil
    }

    /// Which entries the row holds, without their progress: watching moves
    /// offsets every poll, which must not start a pass.
    static func signature(_ sources: [Source]) -> String {
        sources.map { source in
            source.providerID + ":" + source.metas.compactMap(\.ratingKey).sorted().joined(separator: ",")
        }.joined(separator: "|")
    }

    // MARK: - Pass

    private static func run(sources: [Source]) async -> [String: String] {
        var guids: [String] = []
        for source in sources {
            for meta in source.metas where meta.type == "episode" {
                guard let guid = meta.grandparentGuid, guid.hasPrefix("plex://show/"), !guids.contains(guid) else { continue }
                guids.append(guid)
            }
        }
        guids = Array(guids.prefix(maxShows))
        guard !guids.isEmpty else { return [:] }

        // Each server's watch time per show: its recent shows, then a lookup
        // for the shows it did not list.
        var viewed: [[String: Int]] = Array(repeating: [:], count: sources.count)
        await withTaskGroup(of: (Int, [String: Int]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    var times: [String: Int] = [:]
                    for show in await recentShows(on: source.access) {
                        guard let guid = show.guid, guids.contains(guid) else { continue }
                        times[guid] = max(times[guid] ?? 0, show.lastViewedAt ?? 0)
                    }
                    for guid in guids where times[guid] == nil {
                        for show in await lookupShow(guid, on: source.access) {
                            times[guid] = max(times[guid] ?? 0, show.lastViewedAt ?? 0)
                        }
                    }
                    return (index, times)
                }
            }
            for await (index, times) in group { viewed[index] = times }
        }
        return decide(guids: guids, viewed: viewed, providerIDs: sources.map(\.providerID))
    }

    /// For each show held by two or more servers: the one with the latest
    /// watch time (ties keep the earlier, the signed-in server first). Never
    /// watched anywhere, or on one server only: no decision, the hubs stand.
    nonisolated static func decide(guids: [String], viewed: [[String: Int]], providerIDs: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for guid in guids {
            let holders = viewed.indices.filter { viewed[$0][guid] != nil }
            guard holders.count > 1 else { continue }
            var best = holders[0]
            for index in holders.dropFirst() where (viewed[index][guid] ?? 0) > (viewed[best][guid] ?? 0) {
                best = index
            }
            guard (viewed[best][guid] ?? 0) > 0 else { continue }
            result[guid] = providerIDs[best]
        }
        return result
    }

    // MARK: - Requests

    private static func recentShows(on server: OtherServersAvailabilityChecker.ServerAccess) async -> [PlexMetadata] {
        // Container-Size is ignored without Start (CLAUDE.md).
        await metadata("/library/all?type=2&sort=lastViewedAt:desc&X-Plex-Container-Start=0"
                       + "&X-Plex-Container-Size=\(recentShowCount)", on: server) ?? []
    }

    private static func lookupShow(_ guid: String, on server: OtherServersAvailabilityChecker.ServerAccess) async -> [PlexMetadata] {
        guard let encoded = guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        let found = await metadata("/library/all?type=2&guid=\(encoded)&X-Plex-Container-Start=0&X-Plex-Container-Size=10",
                                   on: server) ?? []
        // Checked, not trusted: a server that ignored the filter must not
        // pass its other shows off as this one.
        return found.filter { $0.guid == guid }
    }

    /// The Metadata of one request, nil when the server failed or timed out.
    private static func metadata(_ path: String, on server: OtherServersAvailabilityChecker.ServerAccess) async -> [PlexMetadata]? {
        guard let url = URL(string: server.serverURL + path) else { return nil }
        let headers = PlexNetworkManager.shared.plexHeaders(authToken: server.token)
        let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(
            url, headers: headers, timeout: timeout)
        return container.map { $0.MediaContainer.Metadata ?? [] }
    }
}

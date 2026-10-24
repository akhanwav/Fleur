// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  OtherServersAvailabilityChecker.swift
//  Rivulet
//
//  "On Your Servers" for a metadata-only (TMDB) detail page: is this title on
//  any Plex server this account can reach, OWNED or SHARED, other than the
//  currently selected one? (The selected server's own answer is already why
//  the item is metadata-only — LibraryGUIDIndex already said no.)
//
//  There is no lightweight "does server X have GUID Y" endpoint — the one
//  proven technique in this codebase is the full-library-page-through
//  LibraryGUIDIndex already uses for the selected server (TVSidebarView).
//  This generalizes that same technique to every OTHER accessible server,
//  built lazily (first metadata-only detail page opened this session) and
//  cached in memory for the rest of the session — never persisted to disk,
//  since server membership changes are rare and worth re-deriving per launch
//  rather than risking a stale "available on X" after a share is revoked.
//

import Foundation
import os.log

private let otherServersLog = Logger(subsystem: "com.rivulet.app", category: "OtherServersAvailability")

actor OtherServersAvailabilityChecker {
    static let shared = OtherServersAvailabilityChecker()

    enum Availability: Sendable, Equatable {
        case checking
        case notFound
        case found([String])
    }

    private struct ServerIndex {
        let displayName: String
        var tmdbGuids: Set<String> = []
    }

    private var serverIndexes: [String: ServerIndex] = [:]
    private var buildTask: Task<Void, Never>?

    /// Looks up whether `tmdbId`/`type` is on any other accessible server.
    /// Triggers the one-time background build on first call; subsequent
    /// calls (any title, for the rest of the session) are instant.
    func availability(forTmdbId tmdbId: Int, type: TMDBMediaType) async -> Availability {
        await ensureBuilt()
        let guid = "tmdb://\(tmdbId)"
        let names = serverIndexes.values
            .filter { $0.tmdbGuids.contains(guid) }
            .map(\.displayName)
            .sorted()
        return names.isEmpty ? .notFound : .found(names)
    }

    private func ensureBuilt() async {
        if let buildTask {
            await buildTask.value
            return
        }
        let task = Task { await self.build() }
        buildTask = task
        await task.value
    }

    private func build() async {
        let (authToken, selectedMachineId): (String?, String?) = await MainActor.run {
            (PlexAuthManager.shared.authToken, PlexAuthManager.shared.selectedServer?.machineIdentifier)
        }
        guard let authToken else { return }
        guard let servers = try? await PlexNetworkManager.shared.getServers(authToken: authToken) else {
            otherServersLog.error("[OtherServers] getServers failed; no cross-server availability this session")
            return
        }
        let others = servers.filter { $0.machineIdentifier != nil && $0.machineIdentifier != selectedMachineId }
        guard !others.isEmpty else { return }

        await withTaskGroup(of: (String, ServerIndex)?.self) { group in
            for server in others {
                group.addTask { await Self.buildIndex(for: server) }
            }
            for await result in group {
                guard let (machineId, index) = result else { continue }
                serverIndexes[machineId] = index
            }
        }
        otherServersLog.info("[OtherServers] built \(self.serverIndexes.count, privacy: .public) of \(others.count, privacy: .public) other server(s)")
    }

    /// Resolves a reachable connection, then pages every movie/show section's
    /// full item list (includeGuids) into a tmdb:// guid set. Any failure
    /// (unreachable, no token, no libraries) is a quiet skip, not an error —
    /// a shared server being asleep just means we can't say "available" for
    /// it this session, not that the title isn't there.
    private static func buildIndex(for server: PlexDevice) async -> (String, ServerIndex)? {
        guard let machineId = server.machineIdentifier, let token = server.accessToken else { return nil }
        guard let serverURL = await resolveConnection(server, token: token) else { return nil }
        guard let libraries = try? await PlexNetworkManager.shared.getLibraries(serverURL: serverURL, authToken: token) else {
            return nil
        }

        var index = ServerIndex(displayName: server.sourceTitle ?? server.name)
        let pageSize = 2000
        let maxPagesPerSection = 20   // safety cap: 40,000 items/section

        for library in libraries where library.type == "movie" || library.type == "show" {
            var start = 0
            for _ in 0..<maxPagesPerSection {
                guard let result = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                    serverURL: serverURL,
                    authToken: token,
                    sectionId: library.key,
                    start: start,
                    size: pageSize,
                    includeGuids: true
                ) else { break }

                for item in result.items {
                    for guid in item.Guid ?? [] {
                        if let id = guid.id, id.hasPrefix("tmdb://") { index.tmdbGuids.insert(id) }
                    }
                }
                start += result.items.count
                if result.items.isEmpty || start >= (result.totalSize ?? 0) { break }
            }
        }
        return (machineId, index)
    }

    /// Races this server's connections (local non-relay first, then remote
    /// non-relay, then relay) and returns the first one that answers
    /// `/identity`. Lighter than `PlexAuthManager.findBestConnection` on
    /// purpose — this runs once per OTHER server per session, in parallel
    /// with every other server's own probe, so it doesn't need that method's
    /// last-known-good fast path or raw-HTTPS fallback chain.
    private static func resolveConnection(_ server: PlexDevice, token: String) async -> String? {
        let candidates = (server.connections ?? []).sorted { score($0) > score($1) }
        guard !candidates.isEmpty else { return nil }

        return await withTaskGroup(of: String?.self) { group -> String? in
            for connection in candidates {
                group.addTask {
                    guard let url = URL(string: "\(connection.uri)/identity") else { return nil }
                    struct Probe: Decodable, Sendable {}
                    let headers = PlexNetworkManager.shared.plexHeaders(authToken: token)
                    guard let _: Probe = try? await PlexNetworkManager.shared.request(url, headers: headers, timeout: 6) else {
                        return nil
                    }
                    return connection.uri
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func score(_ connection: PlexConnection) -> Int {
        if connection.relay { return 0 }
        return connection.local ? 2 : 1
    }
}

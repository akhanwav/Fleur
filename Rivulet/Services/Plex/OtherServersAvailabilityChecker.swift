// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  OtherServersAvailabilityChecker.swift
//  Rivulet
//
//  Which Plex servers this account can reach, OWNED or SHARED, hold a given
//  title, and as which items (one server can hold it in several libraries,
//  a 4K one beside a 1080p one): "On Your Servers" and Ways to Watch.
//
//  One title at a time: each server is asked for the title's Plex guid
//  (`/library/all?guid=plex://…`), all servers in parallel, each with a short
//  timeout, so one asleep server costs at most that timeout and never holds up
//  the rest. Plex's agent guid is the same on every server that matched the
//  title; a TMDB id is turned into it once through Discover's matches endpoint.
//
//  This replaced paging every other server's whole library into a guid index
//  (2000 items a page, includeGuids, every movie and show section). On large
//  shared libraries that took minutes, and the pages' decoding filled the
//  cooperative thread pool of a 3-core Apple TV, so every other task in the
//  app (detail fetches, image loads, taps that start a Task) queued behind it.
//

import Foundation
import os.log

private let otherServersLog = Logger(subsystem: "com.rivulet.app", category: "OtherServersAvailability")

actor OtherServersAvailabilityChecker {
    static let shared = OtherServersAvailabilityChecker()

    /// One other-server match: enough to fetch that server's own full
    /// metadata for the item directly.
    struct ServerCopy: Sendable, Hashable {
        let serverName: String
        let serverURL: String
        let token: String
        let ratingKey: String
        let machineId: String
        /// One server can hold a title more than once (a 1080p library and
        /// a 4K one), so a copy is a server AND an item.
        var id: String { "\(machineId):\(ratingKey)" }
    }

    private struct Server: Sendable {
        let machineId: String
        let name: String
        let serverURL: String
        let token: String
    }

    /// Per-server lookup limit: an asleep or slow server is skipped after this.
    private static let lookupTimeout: TimeInterval = 5
    /// Connection probe limit per server, once per `serversTTL`.
    private static let probeTimeout: TimeInterval = 4
    /// Reachable servers are re-resolved after this, so a server that woke up
    /// (or a share that was revoked) shows within minutes, not next launch.
    private static let serversTTL: TimeInterval = 600

    private var serversTask: Task<[Server], Never>?
    private var serversResolvedAt: Date?
    private var copiesCache: [String: [ServerCopy]] = [:]
    private var tmdbGuidCache: [String: String] = [:]

    /// Every copy of `tmdbId` as a `type` on a reachable server, main included.
    func copies(forTmdbId tmdbId: Int, type: TMDBMediaType) async -> [ServerCopy] {
        guard let plexGuid = await plexGuid(forTmdbId: tmdbId, type: type) else { return [] }
        return await copies(plexGuid: plexGuid)
    }

    /// Every copy, on every reachable server (main included), of the title with this Plex guid
    /// ("plex://movie/…", "plex://show/…", "plex://episode/…"), limited to
    /// the servers turned on in Settings and in the user's order. Cached per
    /// guid for the session's server list; the settings apply on every call.
    func copies(plexGuid: String) async -> [ServerCopy] {
        let all = await allCopies(plexGuid: plexGuid)
        return ServerPreferences.sorted(all.filter { ServerPreferences.isEnabled($0.machineId) }, by: \.machineId)
    }

    /// `copies(plexGuid:)` one server at a time: each reachable server's
    /// copies go to `perServer` with its machine id as soon as that server
    /// answers (from the cache, all at once), an empty list included, so a
    /// slow server holds up only its own rows and a caller can tell "has
    /// none" from "has not answered". Returns what every call returned.
    func copies<T: Sendable>(plexGuid: String,
                             perServer: @escaping @Sendable (_ machineId: String, _ copies: [ServerCopy]) async -> [T])
        async -> [T] {
        let servers = await reachableServers()
        if let cached = copiesCache[plexGuid] {
            var results: [T] = []
            for server in servers {
                results += await perServer(server.machineId,
                                           Self.enabled(cached.filter { $0.machineId == server.machineId }))
            }
            return results
        }
        let start = ContinuousClock.now
        var found: [ServerCopy] = []
        var results: [T] = []
        await withTaskGroup(of: ([ServerCopy], [T]).self) { group in
            for server in servers {
                group.addTask {
                    let copies = await Self.lookup(plexGuid, on: server)
                    return (copies, await perServer(server.machineId, Self.enabled(copies)))
                }
            }
            for await (copies, result) in group {
                found += copies
                results += result
            }
        }
        copiesCache[plexGuid] = found.sorted { ($0.serverName, $0.ratingKey) < ($1.serverName, $1.ratingKey) }
        otherServersLog.info("[OtherServers] \(plexGuid, privacy: .public): \(found.count, privacy: .public) of \(servers.count, privacy: .public) server(s) in \(Self.ms(since: start), privacy: .public)ms")
        return results
    }

    private nonisolated static func enabled(_ copies: [ServerCopy]) -> [ServerCopy] {
        ServerPreferences.sorted(copies.filter { ServerPreferences.isEnabled($0.machineId) }, by: \.machineId)
    }

    private func allCopies(plexGuid: String) async -> [ServerCopy] {
        let servers = await reachableServers()
        if let cached = copiesCache[plexGuid] { return cached }
        let start = ContinuousClock.now
        let found = await withTaskGroup(of: [ServerCopy].self) { group in
            for server in servers {
                group.addTask { await Self.lookup(plexGuid, on: server) }
            }
            var found: [ServerCopy] = []
            for await copies in group { found += copies }
            return found.sorted { ($0.serverName, $0.ratingKey) < ($1.serverName, $1.ratingKey) }
        }
        copiesCache[plexGuid] = found
        otherServersLog.info("[OtherServers] \(plexGuid, privacy: .public): \(found.count, privacy: .public) of \(servers.count, privacy: .public) server(s) in \(Self.ms(since: start), privacy: .public)ms")
        return found
    }

    // MARK: - Lookup

    /// Every item on `server` with this guid, across all of its libraries.
    private static func lookup(_ plexGuid: String, on server: Server) async -> [ServerCopy] {
        let start = ContinuousClock.now
        guard var components = URLComponents(string: "\(server.serverURL)/library/all") else { return [] }
        var query = [URLQueryItem(name: "guid", value: plexGuid),
                     // Container-Size is ignored without Start (CLAUDE.md).
                     URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                     URLQueryItem(name: "X-Plex-Container-Size", value: "20")]
        if let type = plexType(of: plexGuid) { query.append(URLQueryItem(name: "type", value: type)) }
        components.queryItems = query
        guard let url = components.url else { return [] }
        let headers = await PlexNetworkManager.shared.plexHeaders(authToken: server.token)
        let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(
            url, headers: headers, timeout: lookupTimeout)
        // Checked, not trusted: a server that ignored the filter must not
        // pass its other items off as this title.
        let matches = (container?.MediaContainer.Metadata ?? []).filter { $0.guid == plexGuid }
        otherServersLog.debug("[OtherServers] \(server.name, privacy: .public): \(matches.count, privacy: .public) copies in \(ms(since: start), privacy: .public)ms\(container == nil ? " (failed or timed out)" : "", privacy: .public)")
        return matches.compactMap { match in
            match.ratingKey.map { ratingKey in
                ServerCopy(serverName: server.name, serverURL: server.serverURL, token: server.token,
                           ratingKey: ratingKey, machineId: server.machineId)
            }
        }
    }

    /// Plex's search type for a guid's kind: movie 1, show 2, episode 4.
    private static func plexType(of plexGuid: String) -> String? {
        if plexGuid.hasPrefix("plex://movie/") { return "1" }
        if plexGuid.hasPrefix("plex://show/") { return "2" }
        if plexGuid.hasPrefix("plex://episode/") { return "4" }
        return nil
    }

    /// A TMDB title's Plex guid. Discover's matches endpoint answers with the
    /// title's Discover ratingKey, which is the id in its plex:// guid.
    func plexGuid(forTmdbId tmdbId: Int, type: TMDBMediaType) async -> String? {
        let key = "\(type.rawValue):\(tmdbId)"
        if let cached = tmdbGuidCache[key] { return cached }
        guard let token = await MainActor.run(body: { PlexAuthManager.shared.authToken }),
              var components = URLComponents(string: "https://metadata.provider.plex.tv/library/metadata/matches")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "type", value: type == .movie ? "1" : "2"),
                                 URLQueryItem(name: "guid", value: "tmdb://\(tmdbId)")]
        guard let url = components.url else { return nil }
        struct Matches: Decodable, Sendable {
            struct Inner: Decodable, Sendable { let Metadata: [Item]? }
            struct Item: Decodable, Sendable { let ratingKey: String?; let guid: String? }
            let MediaContainer: Inner
        }
        let headers = await PlexNetworkManager.shared.plexHeaders(authToken: token)
        guard let matches: Matches = try? await PlexNetworkManager.shared.request(
            url, headers: headers, timeout: Self.lookupTimeout),
              let match = matches.MediaContainer.Metadata?.first
        else {
            otherServersLog.info("[OtherServers] no Discover match for tmdb \(key, privacy: .public)")
            return nil
        }
        // The guid Discover returns, else the one its ratingKey names.
        guard let guid = match.guid?.hasPrefix("plex://") == true ? match.guid
                : match.ratingKey.map({ "plex://\(type == .movie ? "movie" : "show")/\($0)" }) else { return nil }
        tmdbGuidCache[key] = guid
        return guid
    }

    // MARK: - Servers

    /// Resolve the server list now (Settings → Plex Servers lists it).
    func refreshServers() async {
        _ = await reachableServers()
    }

    /// The servers that answered a probe (main included), resolved once per
    /// `serversTTL`. Unreachable servers are left out until the next resolve.
    private func reachableServers() async -> [Server] {
        if let resolvedAt = serversResolvedAt, Date().timeIntervalSince(resolvedAt) > Self.serversTTL {
            serversTask = nil
            copiesCache = [:]
        }
        if let serversTask { return await serversTask.value }
        let task = Task { await Self.resolveServers() }
        serversTask = task
        let servers = await task.value
        serversResolvedAt = Date()
        return servers
    }

    private static func resolveServers() async -> [Server] {
        let start = ContinuousClock.now
        let authToken = await MainActor.run { PlexAuthManager.shared.authToken }
        guard let authToken,
              let devices = try? await PlexNetworkManager.shared.getServers(authToken: authToken) else {
            otherServersLog.error("[OtherServers] getServers failed; no cross-server lookups until the next resolve")
            return []
        }
        // Not `selectedServer` alone: it is nil after a relaunch, which made
        // the main server count as "another" one and list its copy twice.
        let selectedMachineId = await MainActor.run {
            PlexAuthManager.shared.mainServer(in: devices)?.machineIdentifier
        }
        // Settings lists every server, main included, without a fetch of its own.
        // Written on the main actor: a UserDefaults write posts its change
        // notification on the writing thread, and the app's defaults
        // observers (Home, @AppStorage) expect the main thread.
        let known: [ServerPreferences.KnownServer] = devices.compactMap { device in
            guard let id = device.machineIdentifier, device.provides.contains("server") else { return nil }
            return .init(machineId: id, name: device.sourceTitle ?? device.name)
        }
        await MainActor.run {
            ServerPreferences.setMainMachineId(selectedMachineId)
            ServerPreferences.remember(known)
        }
        let others = devices.filter { $0.machineIdentifier != nil && $0.machineIdentifier != selectedMachineId }
        // The main server is searched too, on the connection the app already
        // uses: it can hold a title twice (a 4K library beside a 1080p one).
        // Callers drop the copy their page already shows.
        let main: Server? = await MainActor.run {
            let auth = PlexAuthManager.shared
            guard let id = selectedMachineId, let url = auth.selectedServerURL,
                  let token = auth.selectedServerToken else { return nil }
            return Server(machineId: id, name: auth.mainServerName ?? "Main Server", serverURL: url, token: token)
        }
        var servers = await withTaskGroup(of: Server?.self) { group in
            for device in others {
                group.addTask {
                    guard let machineId = device.machineIdentifier, let token = device.accessToken,
                          let url = await resolveConnection(device, token: token) else { return nil }
                    return Server(machineId: machineId, name: device.sourceTitle ?? device.name,
                                  serverURL: url, token: token)
                }
            }
            var servers: [Server] = []
            for await server in group { if let server { servers.append(server) } }
            return servers
        }
        if let main { servers.append(main) }
        otherServersLog.info("[OtherServers] \(servers.count, privacy: .public) of \(others.count + 1, privacy: .public) server(s) reachable, resolved in \(ms(since: start), privacy: .public)ms")
        return servers
    }

    /// Races this server's connections (local non-relay first, then remote
    /// non-relay, then relay) and returns the first one that answers
    /// `/identity`, each probe capped at `probeTimeout`.
    private static func resolveConnection(_ server: PlexDevice, token: String) async -> String? {
        let candidates = (server.connections ?? []).sorted { score($0) > score($1) }
        guard !candidates.isEmpty else { return nil }

        return await withTaskGroup(of: String?.self) { group -> String? in
            for connection in candidates {
                group.addTask {
                    guard let url = URL(string: "\(connection.uri)/identity") else { return nil }
                    struct Probe: Decodable, Sendable {}
                    let headers = await PlexNetworkManager.shared.plexHeaders(authToken: token)
                    guard let _: Probe = try? await PlexNetworkManager.shared.request(
                        url, headers: headers, timeout: probeTimeout) else { return nil }
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

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

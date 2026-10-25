// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  OtherServersAvailabilityChecker.swift
//  Rivulet
//
//  Which Plex servers this account can reach, OWNED or SHARED, other than the
//  selected one, hold a given title — "On Your Servers" on an unowned detail
//  page and the other-server rows of Ways to Watch.
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

    /// Every other reachable server holding `tmdbId` as a `type`.
    func copies(forTmdbId tmdbId: Int, type: TMDBMediaType) async -> [ServerCopy] {
        guard let plexGuid = await plexGuid(forTmdbId: tmdbId, type: type) else { return [] }
        return await copies(plexGuid: plexGuid)
    }

    /// Every other reachable server holding the title with this Plex guid
    /// ("plex://movie/…", "plex://show/…", "plex://episode/…"), limited to
    /// the servers turned on in Settings and in the user's order. Cached per
    /// guid for the session's server list; the settings apply on every call.
    func copies(plexGuid: String) async -> [ServerCopy] {
        let all = await allCopies(plexGuid: plexGuid)
        return ServerPreferences.sorted(all.filter { ServerPreferences.isEnabled($0.machineId) }, by: \.machineId)
    }

    private func allCopies(plexGuid: String) async -> [ServerCopy] {
        let servers = await reachableServers()
        if let cached = copiesCache[plexGuid] { return cached }
        let start = ContinuousClock.now
        let found = await withTaskGroup(of: ServerCopy?.self) { group in
            for server in servers {
                group.addTask { await Self.lookup(plexGuid, on: server) }
            }
            var found: [ServerCopy] = []
            for await copy in group { if let copy { found.append(copy) } }
            return found.sorted { $0.serverName < $1.serverName }
        }
        copiesCache[plexGuid] = found
        otherServersLog.info("[OtherServers] \(plexGuid, privacy: .public): \(found.count, privacy: .public) of \(servers.count, privacy: .public) server(s) in \(Self.ms(since: start), privacy: .public)ms")
        return found
    }

    // MARK: - Lookup

    private static func lookup(_ plexGuid: String, on server: Server) async -> ServerCopy? {
        let start = ContinuousClock.now
        guard var components = URLComponents(string: "\(server.serverURL)/library/all") else { return nil }
        var query = [URLQueryItem(name: "guid", value: plexGuid),
                     // Container-Size is ignored without Start (CLAUDE.md).
                     URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                     URLQueryItem(name: "X-Plex-Container-Size", value: "5")]
        if let type = plexType(of: plexGuid) { query.append(URLQueryItem(name: "type", value: type)) }
        components.queryItems = query
        guard let url = components.url else { return nil }
        let headers = await PlexNetworkManager.shared.plexHeaders(authToken: server.token)
        let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(
            url, headers: headers, timeout: lookupTimeout)
        // Checked, not trusted: a server that ignored the filter must not
        // pass its first item off as this title.
        let match = container?.MediaContainer.Metadata?.first { $0.guid == plexGuid }
        otherServersLog.debug("[OtherServers] \(server.name, privacy: .public): \(match == nil ? "no" : "yes", privacy: .public) in \(ms(since: start), privacy: .public)ms\(container == nil ? " (failed or timed out)" : "", privacy: .public)")
        guard let ratingKey = match?.ratingKey else { return nil }
        return ServerCopy(serverName: server.name, serverURL: server.serverURL, token: server.token,
                          ratingKey: ratingKey, machineId: server.machineId)
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
            struct Item: Decodable, Sendable { let ratingKey: String? }
            let MediaContainer: Inner
        }
        let headers = await PlexNetworkManager.shared.plexHeaders(authToken: token)
        guard let matches: Matches = try? await PlexNetworkManager.shared.request(
            url, headers: headers, timeout: Self.lookupTimeout),
              let ratingKey = matches.MediaContainer.Metadata?.first?.ratingKey
        else { return nil }
        let guid = "plex://\(type == .movie ? "movie" : "show")/\(ratingKey)"
        tmdbGuidCache[key] = guid
        return guid
    }

    // MARK: - Servers

    /// Resolve the server list now (Settings → Plex Servers lists it).
    func refreshServers() async {
        _ = await reachableServers()
    }

    /// The other servers that answered a probe, resolved once per
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
        let (authToken, selectedMachineId): (String?, String?) = await MainActor.run {
            (PlexAuthManager.shared.authToken, PlexAuthManager.shared.selectedServer?.machineIdentifier)
        }
        guard let authToken,
              let devices = try? await PlexNetworkManager.shared.getServers(authToken: authToken) else {
            otherServersLog.error("[OtherServers] getServers failed; no cross-server lookups until the next resolve")
            return []
        }
        // Settings lists every server, main included, without a fetch of its own.
        ServerPreferences.setMainMachineId(selectedMachineId)
        ServerPreferences.remember(devices.compactMap { device in
            guard let id = device.machineIdentifier, device.provides.contains("server") else { return nil }
            return .init(machineId: id, name: device.sourceTitle ?? device.name)
        })
        let others = devices.filter { $0.machineIdentifier != nil && $0.machineIdentifier != selectedMachineId }
        let servers = await withTaskGroup(of: Server?.self) { group in
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
        otherServersLog.info("[OtherServers] \(servers.count, privacy: .public) of \(others.count, privacy: .public) other server(s) reachable, resolved in \(ms(since: start), privacy: .public)ms")
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

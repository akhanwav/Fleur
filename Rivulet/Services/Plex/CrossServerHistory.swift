//
//  CrossServerHistory.swift
//  Rivulet
//
//  Gathers each server's watch history for the shows Continue Watching could
//  offer, and decides one episode per show with `CrossServerNextUp`.
//
//  The shows: every show in any server's Continue Watching, plus each server's
//  recently watched shows (`/library/all?type=2&sort=lastViewedAt:desc`, one
//  small request), so a new episode on a server the show was never watched on
//  still surfaces. A show is read per server as its seasons, then only the
//  furthest season with progress and the one after it: a long show's
//  `allLeaves` is about 1 MB and 300 to 500 ms. Both are cached until the
//  show's watched count, episode count or last-watched time changes.
//
//  Runs when the shows in Continue Watching change, and at most every 15
//  minutes otherwise. The account's own profile only, like every feature
//  that reaches other servers (`OtherServersAvailabilityChecker.lookupServers`).
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

    /// The decision per show guid. Empty until the first pass ends.
    private(set) var outcomes: [String: CrossServerNextUp.Outcome] = [:]
    /// Called on the main actor when `outcomes` changed.
    var onChange: (() -> Void)?

    /// Plex's default "Weeks to consider for Continue Watching" (`OnDeckWindow`).
    /// A shared server does not show its own value to the people it is shared with.
    static let window: TimeInterval = 16 * 7 * 86_400
    static let interval: TimeInterval = 15 * 60
    private static let recentShowCount = 20
    private static let maxShows = 30
    private static let timeout: TimeInterval = 8
    private static let concurrentShows = 6

    private var task: Task<Void, Never>?
    private var lastRun: Date?
    private var lastSignature: String?
    private var cache: [String: CachedShow] = [:]

    private struct CachedShow {
        let fingerprint: String
        var seasons: [PlexMetadata]
        var episodes: [Int: [PlexMetadata]] = [:]
    }

    /// Run a pass when the shows in Continue Watching changed, or the last
    /// pass is older than `interval`.
    func refresh(sources: [Source], now: Date = Date()) {
        guard task == nil else { return }
        guard sources.count > 1 else {
            if !outcomes.isEmpty { outcomes = [:]; onChange?() }
            return
        }
        let signature = Self.signature(sources)
        if signature == lastSignature, let lastRun, now.timeIntervalSince(lastRun) < Self.interval { return }
        lastSignature = signature
        lastRun = now
        task = Task { [weak self] in
            guard let self else { return }
            let next = await self.run(sources: sources, now: now)
            // Reset while it ran: a newer pass, or none, owns the state now.
            guard !Task.isCancelled else { return }
            self.task = nil
            self.outcomes = next
            self.onChange?()
        }
    }

    /// Sign-out or a profile switch: nothing carries over.
    func reset() {
        task?.cancel()
        task = nil
        outcomes = [:]
        cache = [:]
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

    private func run(sources: [Source], now: Date) async -> [String: CrossServerNextUp.Outcome] {
        let cutoff = Int(now.addingTimeInterval(-Self.window).timeIntervalSince1970)
        var recents: [[PlexMetadata]] = []
        for source in sources {
            recents.append(await Self.recentShows(on: source.access).filter { ($0.lastViewedAt ?? 0) >= cutoff })
        }

        // Shows in some server's Continue Watching first, then recent ones.
        var guids: [String] = []
        var inHub: Set<String> = []
        for source in sources {
            for meta in source.metas where meta.type == "episode" {
                guard let guid = meta.grandparentGuid, guid.hasPrefix("plex://show/"), !inHub.contains(guid) else { continue }
                inHub.insert(guid)
                guids.append(guid)
            }
        }
        let recent = recents.flatMap { $0 }
            .sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
            .compactMap(\.guid)
        for guid in recent where guid.hasPrefix("plex://show/") && !guids.contains(guid) {
            guids.append(guid)
        }
        guids = Array(guids.prefix(Self.maxShows))

        var result: [String: CrossServerNextUp.Outcome] = [:]
        // A few shows at a time: each is a handful of small requests per server.
        var start = 0
        while start < guids.count, !Task.isCancelled {
            let chunk = guids[start..<min(start + Self.concurrentShows, guids.count)]
            start += Self.concurrentShows
            await withTaskGroup(of: (String, CrossServerNextUp.Outcome?).self) { group in
                for guid in chunk {
                    group.addTask { @MainActor in
                        (guid, await self.outcome(for: guid, sources: sources, recents: recents,
                                                  listed: inHub.contains(guid)))
                    }
                }
                for await (guid, outcome) in group { result[guid] = outcome }
            }
        }
        return result
    }

    /// One show's decision; nil when one server or none holds it, where that
    /// server's own On Deck already has the whole history.
    private func outcome(for guid: String, sources: [Source], recents: [[PlexMetadata]],
                         listed: Bool) async -> CrossServerNextUp.Outcome? {
        // Each server's copies of the show: from its recent list, else looked up.
        var shows: [[PlexMetadata]] = []
        for (index, source) in sources.enumerated() {
            let known = recents[index].filter { $0.guid == guid }
            shows.append(known.isEmpty ? await Self.lookupShow(guid, on: source.access) : known)
        }
        guard shows.filter({ !$0.isEmpty }).count > 1 else { return nil }

        var seasonsByServer: [[PlexMetadata]] = []
        for (index, source) in sources.enumerated() {
            var seasons: [PlexMetadata] = []
            for show in shows[index] { seasons += await seasonList(show, on: source.access) }
            seasonsByServer.append(seasons)
        }
        let entries = sources.map { $0.metas.filter { $0.grandparentGuid == guid } }
        guard let furthest = zip(seasonsByServer, entries).compactMap({
            CrossServerNextUp.furthestSeason(seasons: $0.0, entries: $0.1)
        }).max() else { return .noHistory }

        var servers: [CrossServerNextUp.ServerShow] = []
        for (index, source) in sources.enumerated() {
            var episodes = entries[index]
            for show in shows[index] {
                let available = (cache[Self.key(show, source.access)]?.seasons ?? []).compactMap(\.index)
                for season in CrossServerNextUp.seasonsToFetch(furthest: furthest, available: available) {
                    episodes += await seasonEpisodes(show, season: season, on: source.access)
                }
            }
            let lastViewed = shows[index].compactMap(\.lastViewedAt).max() ?? 0
            servers.append(.init(providerID: source.providerID, lastViewedAt: lastViewed, episodes: episodes))
        }
        let outcome = CrossServerNextUp.outcome(showGuid: guid, servers: servers)
        // A show no row lists: the server it was last watched on left it out
        // on purpose (removed, or outside its window) when it holds the
        // episode. Offer it only from servers where that episode is new.
        if !listed, case .cards(let cards) = outcome {
            let latest = servers.max { $0.lastViewedAt < $1.lastViewedAt }?.providerID
            return cards.contains { $0.providerID == latest } ? .noHistory : outcome
        }
        return outcome
    }

    // MARK: - Requests

    private static func key(_ show: PlexMetadata, _ server: OtherServersAvailabilityChecker.ServerAccess) -> String {
        "\(server.machineId)|\(show.ratingKey ?? "")"
    }

    private static func fingerprint(_ show: PlexMetadata) -> String {
        "\(show.lastViewedAt ?? 0)|\(show.viewedLeafCount ?? 0)|\(show.leafCount ?? 0)|\(show.childCount ?? 0)"
    }

    private func seasonList(_ show: PlexMetadata, on server: OtherServersAvailabilityChecker.ServerAccess) async -> [PlexMetadata] {
        let key = Self.key(show, server)
        let fingerprint = Self.fingerprint(show)
        if let cached = cache[key], cached.fingerprint == fingerprint { return cached.seasons }
        guard let ratingKey = show.ratingKey,
              let seasons = await Self.metadata("/library/metadata/\(ratingKey)/children", on: server) else {
            return cache[key]?.seasons ?? []
        }
        guard !Task.isCancelled else { return seasons }
        cache[key] = CachedShow(fingerprint: fingerprint, seasons: seasons)
        return seasons
    }

    private func seasonEpisodes(_ show: PlexMetadata, season: Int,
                                on server: OtherServersAvailabilityChecker.ServerAccess) async -> [PlexMetadata] {
        let key = Self.key(show, server)
        guard var cached = cache[key] else { return [] }
        if let episodes = cached.episodes[season] { return episodes }
        guard let ratingKey = cached.seasons.first(where: { $0.index == season })?.ratingKey,
              let episodes = await Self.metadata("/library/metadata/\(ratingKey)/children", on: server) else {
            return []
        }
        guard !Task.isCancelled else { return episodes }
        cached.episodes[season] = episodes
        cache[key] = cached
        return episodes
    }

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

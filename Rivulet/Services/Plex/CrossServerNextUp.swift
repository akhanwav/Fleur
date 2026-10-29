//
//  CrossServerNextUp.swift
//  Rivulet
//
//  The episode Continue Watching offers for a show watched on more than one
//  server. Each server's On Deck knows only its own history, so one server
//  can offer an episode already watched on another (or one before it). This
//  reads every server's history for the show and picks once:
//
//  - The most recent activity anywhere is a partly watched episode within
//    `window`: resume it, even when another server has the whole show
//    watched (a rewatch). An older one stays hidden.
//  - Otherwise the first episode after the furthest one watched anywhere, by
//    season and number (specials are left out). None on any server: no card.
//
//  One card per quality, each on the server where the show was watched most
//  recently among those holding that copy. Watch states are only read.
//

import Foundation

nonisolated enum CrossServerNextUp {

    /// One server's copies of a show.
    struct ServerShow: Sendable {
        /// The server as Continue Watching names it (`plex:<machineId>`, or the main provider's id).
        let providerID: String
        /// When the show was last watched on this server (Unix seconds); 0 never.
        let lastViewedAt: Int
        /// The episodes known on this server: the seasons that decide the
        /// pick, plus its Continue Watching entries for the show.
        let episodes: [PlexMetadata]
    }

    struct Card: Sendable {
        let providerID: String
        let meta: PlexMetadata
    }

    enum Outcome: Sendable {
        /// Never watched on any server: Plex's own entries stand.
        case noHistory
        /// Watched through the last episode any server has: no card.
        case caughtUp
        /// One card per quality.
        case cards([Card])
    }

    /// How much later than a partly watched episode another watch may be
    /// and still leave that episode the one to resume: a stop and the
    /// server's own show timestamp land a few seconds apart.
    static let resumeTolerance = 60

    /// Plex's default "Weeks to consider for Continue Watching" (`OnDeckWindow`).
    /// A shared server does not show its own value to the people it is shared with.
    static let window: TimeInterval = 16 * 7 * 86_400

    /// The episode to offer for one show (`showGuid`), from every server's copies.
    static func outcome(showGuid: String, servers: [ServerShow], now: Date = Date()) -> Outcome {
        struct Copy { let server: Int; let meta: PlexMetadata; let order: Int }
        var copies: [Copy] = []
        for (index, server) in servers.enumerated() {
            for meta in server.episodes {
                guard let order = order(meta) else { continue }
                copies.append(Copy(server: index, meta: meta, order: order))
            }
        }
        let watched = copies.filter { ($0.meta.viewCount ?? 0) > 0 }
        let partial = copies.filter { ($0.meta.viewOffset ?? 0) > 0 }
        guard !watched.isEmpty || !partial.isEmpty else { return .noHistory }

        let lastActivity = max(servers.map(\.lastViewedAt).max() ?? 0,
                               copies.map { $0.meta.lastViewedAt ?? 0 }.max() ?? 0)
        let windowStart = Int(now.timeIntervalSince1970 - window)
        let resumable = partial.max { ($0.meta.lastViewedAt ?? 0) < ($1.meta.lastViewedAt ?? 0) }.flatMap { copy -> Copy? in
            let at = copy.meta.lastViewedAt ?? 0
            guard at >= windowStart, at + resumeTolerance >= lastActivity || watched.isEmpty else { return nil }
            return copy
        }

        let target: Int
        var resume: PlexMetadata?
        if let resumable {
            target = resumable.order
            resume = resumable.meta
        } else {
            // Only an old partial watch: Plex's own window decides.
            guard !watched.isEmpty else { return .noHistory }
            let furthest = watched.map(\.order).max() ?? 0
            guard let next = copies.map(\.order).filter({ $0 > furthest }).min() else { return .caughtUp }
            target = next
        }

        // One copy per quality: the server watched most recently, then the
        // order the servers were given in (the main server first).
        var best: [String: Copy] = [:]
        var qualities: [String] = []
        for copy in copies where copy.order == target {
            let quality = PlexDataStore.qualityKey(copy.meta)
            guard let current = best[quality] else {
                best[quality] = copy
                qualities.append(quality)
                continue
            }
            let a = servers[copy.server].lastViewedAt, b = servers[current.server].lastViewedAt
            if a > b || (a == b && copy.server < current.server) { best[quality] = copy }
        }
        let cards = qualities.compactMap { best[$0] }.map { copy -> Card in
            var meta = copy.meta
            meta.viewOffset = resume?.viewOffset ?? 0
            // Sorted with the show's most recent watch on any server.
            meta.lastViewedAt = lastActivity
            meta.grandparentGuid = showGuid
            return Card(providerID: servers[copy.server].providerID, meta: meta)
        }
        return .cards(cards)
    }

    /// An episode's place in the show, specials and unnumbered ones excluded.
    static func order(_ meta: PlexMetadata) -> Int? {
        guard let season = meta.parentIndex, season > 0, let episode = meta.index else { return nil }
        return season * 100_000 + episode
    }

    /// The highest season with progress on a server: one with a watched
    /// episode (`seasons`, a show's children), or one holding a partly
    /// watched entry (`entries`). The seasons worth fetching start there.
    static func furthestSeason(seasons: [PlexMetadata], entries: [PlexMetadata]) -> Int? {
        let watched = seasons.compactMap { season -> Int? in
            guard let index = season.index, index > 0, (season.viewedLeafCount ?? 0) > 0 else { return nil }
            return index
        }
        let partial = entries.compactMap { meta -> Int? in
            guard (meta.viewOffset ?? 0) > 0, let season = meta.parentIndex, season > 0 else { return nil }
            return season
        }
        return (watched + partial).max()
    }

    /// The seasons to read on a server once the furthest season anywhere is
    /// known: that season and the first one after it, where this server has them.
    static func seasonsToFetch(furthest: Int, available: [Int]) -> [Int] {
        let after = available.filter { $0 > furthest }.min()
        return ([furthest] + (after.map { [$0] } ?? [])).filter(available.contains)
    }
}

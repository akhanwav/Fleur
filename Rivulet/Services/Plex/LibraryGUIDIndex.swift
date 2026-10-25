// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryGUIDIndex.swift
//  Rivulet
//
//  In-memory index of library items keyed by external GUIDs (TMDB/IMDB/TVDB).
//  Used by Discover and Watchlist surfaces to answer "do I own this?" in O(1).
//

import Foundation
import os.log

private let guidIndexLog = Logger(subsystem: "com.rivulet.app", category: "LibraryGUIDIndex")

extension Notification.Name {
    /// Posted on the main thread after `LibraryGUIDIndex.shared.replace(with:completeness:)`
    /// completes. Views observing this can re-run library-match queries.
    static let libraryGUIDIndexDidUpdate = Notification.Name("LibraryGUIDIndexDidUpdate")
}

actor LibraryGUIDIndex {
    static let shared = LibraryGUIDIndex()

    private struct TypedKey: Hashable {
        let type: PlexItemType
        let tmdbId: Int
    }

    enum PlexItemType: Hashable {
        case movie
        case show
    }

    /// One indexed title: the list-level fields the index's callers show (a
    /// tile, a hero slide, a watchlist badge) and its external GUIDs, nothing
    /// else.
    ///
    /// The index used to keep each title's whole `PlexMetadata`, which is about
    /// 80 optionals stored inline plus every tag, genre and Media array of the
    /// `/all` listing: 3.3 KB a title, measured. A shared server with 166,000
    /// titles held 670 MB in it on an Apple TV, and the build kept growing
    /// until jetsam killed the app at the 2 GB limit. An entry is a few hundred
    /// bytes, and each page of the build is reduced to entries as it arrives.
    struct Entry: Codable, Sendable {
        let ratingKey: String?
        let key: String?
        let guid: String?
        let type: String?
        let title: String?
        let editionTitle: String?
        let year: Int?
        let summary: String?
        let tagline: String?
        /// Only the first genre: the hero's metadata row shows no other.
        let genre: String?
        let contentRating: String?
        let duration: Int?
        let originallyAvailableAt: String?
        let addedAt: Int?
        let thumb: String?
        let art: String?
        let clearLogo: String?
        let librarySectionID: Int?
        let viewCount: Int?
        let viewOffset: Int?
        let lastViewedAt: Int?
        let userRating: Double?
        let leafCount: Int?
        let viewedLeafCount: Int?
        let childCount: Int?
        /// Distinct Media versions, which drive the version picker.
        let versionCount: Int?
        let externalGuids: [String]

        /// nil for anything the index does not answer for: a type other than
        /// movie or show, or a title with no external GUID to find it by.
        init?(_ item: PlexMetadata) {
            guard item.type == "movie" || item.type == "show" else { return nil }
            let externalGuids = (item.Guid ?? []).compactMap(\.id)
            guard !externalGuids.isEmpty else { return nil }
            ratingKey = item.ratingKey
            key = item.key
            guid = item.guid
            type = item.type
            title = item.title
            editionTitle = item.editionTitle
            year = item.year
            summary = item.summary
            tagline = item.tagline
            genre = item.Genre?.first?.tag
            contentRating = item.contentRating
            duration = item.duration
            originallyAvailableAt = item.originallyAvailableAt
            addedAt = item.addedAt
            thumb = item.thumb
            art = item.art
            clearLogo = item.clearLogoPath
            librarySectionID = item.librarySectionID
            viewCount = item.viewCount
            viewOffset = item.viewOffset
            lastViewedAt = item.lastViewedAt
            userRating = item.userRating
            leafCount = item.leafCount
            viewedLeafCount = item.viewedLeafCount
            childCount = item.childCount
            versionCount = item.Media.map { Set($0.map(\.id)).count }
            self.externalGuids = externalGuids
        }

        /// The list-level item callers get back. Built per lookup, so the index
        /// never holds one.
        var metadata: PlexMetadata {
            var item = PlexMetadata(
                ratingKey: ratingKey,
                key: key,
                guid: guid,
                type: type,
                title: title,
                contentRating: contentRating,
                summary: summary,
                tagline: tagline,
                year: year,
                thumb: thumb,
                art: art,
                Genre: genre.map { [PlexTag(_id: nil, tag: $0)] },
                duration: duration,
                originallyAvailableAt: originallyAvailableAt,
                addedAt: addedAt,
                librarySectionID: librarySectionID,
                leafCount: leafCount,
                viewedLeafCount: viewedLeafCount,
                childCount: childCount,
                viewCount: viewCount,
                viewOffset: viewOffset,
                lastViewedAt: lastViewedAt,
                userRating: userRating,
                // Only the count survives; the stubs exist so `versionCount`
                // maps the same as from the full listing.
                Media: versionCount.map { count in
                    (0..<count).map {
                        PlexMedia(id: $0, duration: nil, bitrate: nil, width: nil, height: nil,
                                  aspectRatio: nil, audioChannels: nil, audioCodec: nil, videoCodec: nil,
                                  videoResolution: nil, container: nil, videoFrameRate: nil, Part: nil)
                    }
                }
            )
            item.editionTitle = editionTitle
            item.Guid = externalGuids.map { PlexGuid(id: $0) }
            item.Image = clearLogo.map { [PlexImage(alt: nil, type: "clearLogo", url: $0)] }
            return item
        }
    }

    private var entries: [Entry] = []
    private var byTypedTmdbId: [TypedKey: Int] = [:]
    private var byGuid: [String: Int] = [:]

    /// Live network data always supersedes a disk-hydrated snapshot. Once a real
    /// `replace(with:completeness:)` has run this launch, a late `hydrateFromDisk()`
    /// is a no-op so stale disk contents can't clobber fresh server data. This is
    /// set for partial builds too, since a partial live snapshot is still more
    /// current than the disk copy.
    private var hasFreshData = false

    /// Bumped on every rebuild. Consumers (e.g. the trending hero) read this to
    /// skip recomputation when the index hasn't actually changed since their last
    /// run, so overlapping triggers don't repeat identical work.
    private(set) var generation = 0

    /// Whether a network rebuild saw every library section, every page, all the
    /// way through. Only a complete build is allowed to overwrite the disk cache.
    ///
    /// This exists because a truncated snapshot is indistinguishable from a good
    /// one once it has been written: `DiskCache` stores only a version, a date and
    /// the items, so the next launch's `hydrateFromDisk()` will load a half-built
    /// index and treat it as authoritative. The failure is completely silent. The
    /// user just sees fewer "in your library" badges, a thinner TMDB hero, and
    /// Discover items that will not resolve to something playable, with no error
    /// anywhere. Worse, the damage outlives the network blip that caused it: every
    /// subsequent launch starts from the degraded snapshot until a fully successful
    /// rebuild happens to land. A single timed-out page at offset 5000 of a 12,000
    /// item library is enough to do this.
    ///
    /// So the rule is: a partial build may update the in-memory index, because
    /// partial data still beats nothing for the current launch, but it must never
    /// touch disk. Do not collapse this into a defaulted parameter. Every caller
    /// has to say which it has, precisely so a new call site cannot quietly inherit
    /// "complete" and reintroduce the silent corruption.
    enum Completeness: Sendable {
        /// Every visible section returned every page without error. Safe to persist.
        case complete
        /// At least one section failed or was cut short. In-memory only.
        case partial
    }

    /// Rebuild the index from a freshly-fetched library snapshot and notify
    /// observers. This is the authoritative path — it always wins over
    /// `hydrateFromDisk()`, complete or not, because even a partial live snapshot
    /// is more current than last launch's disk contents.
    ///
    /// Persists to disk only when `completeness` is `.complete`. See the
    /// `Completeness` doc comment for why a partial build must not be written.
    func replace(with items: [Entry], completeness: Completeness) {
        rebuild(from: items, source: "replace")

        // Set regardless of completeness. `hasFreshData` guards against a late
        // `hydrateFromDisk()` overwriting live server data with the older disk
        // snapshot, and that ordering hazard is identical whether this build was
        // complete or not. Leaving it false on a partial build would let a
        // straggling hydrate replace a partial-but-current index with a
        // possibly-worse one from disk.
        hasFreshData = true

        // Deliberately no log line on the partial branch: the caller already
        // reports the incomplete-section count when it finishes the build, and
        // guidIndexLog carries pre-existing actor-isolation warnings we are not
        // adding to.
        if case .complete = completeness {
            persist(items)
        }
    }

    /// Populate the index from the last persisted snapshot. Cheap (local decode),
    /// so it runs at launch to make "do I own this?" answers available before the
    /// ~20MB network refresh lands. Skips if fresh network data already arrived.
    /// Returns the number of items hydrated (0 = miss / skipped / decode failure).
    func hydrateFromDisk() -> Int {
        guard !hasFreshData else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk skipped: fresh network data already present")
            return 0
        }
        guard let items = Self.loadFromDisk() else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk miss: no valid cache on disk")
            return 0
        }
        rebuild(from: items, source: "hydrateFromDisk")
        return items.count
    }

    /// Shared ingest + notify used by both `replace` and `hydrateFromDisk`.
    private func rebuild(from items: [Entry], source: String) {
        entries = items
        byTypedTmdbId.removeAll(keepingCapacity: true)
        byGuid.removeAll(keepingCapacity: true)

        for (position, item) in items.enumerated() {
            ingest(item, at: position)
        }
        generation += 1

        let typedCount = byTypedTmdbId.count
        let guidCount = byGuid.count
        guidIndexLog.info("[Hero] LibraryGUIDIndex.\(source, privacy: .public): ingested \(items.count, privacy: .public) items -> typedTmdbCount=\(typedCount, privacy: .public), guidCount=\(guidCount, privacy: .public)")
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .libraryGUIDIndexDidUpdate,
                object: nil,
                userInfo: ["typedTmdbCount": typedCount, "guidCount": guidCount]
            )
        }
    }

    var isEmpty: Bool {
        byGuid.isEmpty
    }

    func lookup(tmdbId: Int, type: TMDBMediaType) -> PlexMetadata? {
        let plexType: PlexItemType = (type == .movie) ? .movie : .show
        return byTypedTmdbId[TypedKey(type: plexType, tmdbId: tmdbId)].map { entries[$0].metadata }
    }

    func lookup(guid: String) -> PlexMetadata? {
        byGuid[guid].map { entries[$0].metadata }
    }

    func contains(guid: String) -> Bool {
        byGuid[guid] != nil
    }

    // MARK: - Ingestion

    private func ingest(_ item: Entry, at position: Int) {
        let plexType: PlexItemType
        switch item.type {
        case "movie": plexType = .movie
        case "show": plexType = .show
        default: return
        }

        for raw in item.externalGuids {
            byGuid[raw] = position

            if let tmdbId = Self.tmdbId(from: raw) {
                byTypedTmdbId[TypedKey(type: plexType, tmdbId: tmdbId)] = position
            }
        }
    }

    private static func tmdbId(from guid: String) -> Int? {
        guard guid.hasPrefix("tmdb://") else { return nil }
        let raw = guid.dropFirst("tmdb://".count)
        return Int(raw)
    }

    // MARK: - Disk persistence

    /// Bump when the persisted shape changes so old caches are ignored, not
    /// mis-decoded, on the next launch after an app update.
    /// 2: entries replaced whole `PlexMetadata` items.
    private static let cacheVersion = 2

    private struct DiskCache: Codable {
        let version: Int
        let savedAt: Date
        let items: [Entry]
    }

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        // One snapshot per Home profile: what is "in your library" depends on who looks.
        let owner = UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey)
        return dir.appendingPathComponent(owner == 0 ? "library-guid-index.json" : "library-guid-index-\(owner).json")
    }

    /// Another profile owns the content now: drop the previous one's answers
    /// and take this profile's last snapshot.
    func profileChanged() {
        hasFreshData = false
        rebuild(from: Self.loadFromDisk() ?? [], source: "profileChanged")
    }

    /// Persist the ingested snapshot for the next launch. Fire-and-forget on a
    /// background task so the encode + write never serializes behind other
    /// actor work or the caller's critical path.
    private func persist(_ items: [Entry]) {
        guard let url = Self.cacheURL else { return }
        Task.detached(priority: .utility) {
            let cache = DiskCache(version: Self.cacheVersion, savedAt: Date(), items: items)
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
                guidIndexLog.info("[GUIDIndex] persisted \(items.count, privacy: .public) items (\(data.count / 1024, privacy: .public) KB) to disk")
            } catch {
                guidIndexLog.error("[GUIDIndex] persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Load and validate the persisted snapshot. Returns nil on miss, version
    /// mismatch, or decode failure (caller falls back to the network build).
    private static func loadFromDisk() -> [Entry]? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let cache = try? JSONDecoder().decode(DiskCache.self, from: data) else {
            guidIndexLog.error("[GUIDIndex] disk cache decode failed; ignoring")
            return nil
        }
        guard cache.version == cacheVersion else {
            guidIndexLog.info("[GUIDIndex] disk cache version \(cache.version, privacy: .public) != \(cacheVersion, privacy: .public); ignoring")
            return nil
        }
        return cache.items
    }
}

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
    /// Posted on the main thread after `LibraryGUIDIndex.shared.replace(with:changed:)`
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

    /// One library section's entries, read from the server whole. The index and
    /// its snapshot are a set of these, so a section that failed to load costs
    /// that section and nothing else: the others stay current and saved, and a
    /// half-read section never exists to be mistaken for a complete one.
    struct Section: Sendable {
        let key: String
        /// The server the section was read from. Section keys are per server, so
        /// a saved section is never reused against another one.
        let serverID: String?
        /// What the section looked like when it was read
        /// (`LibraryGUIDIndexBuilder.signature`). A launch compares it with the
        /// server's current one to decide whether the section needs reading again.
        let signature: String?
        let fetchedAt: Date
        let entries: [Entry]
    }

    /// Visible-library order. Positions in the lookup tables are
    /// `section << 32 | entry`, so no entry is ever stored twice.
    private var sections: [Section] = []
    private var byTypedTmdbId: [TypedKey: Int] = [:]
    private var byGuid: [String: Int] = [:]

    /// Live network data always supersedes a disk-hydrated snapshot. Once a real
    /// `replace(with:changed:)` has run this launch, a late `hydrateFromDisk()`
    /// is a no-op so stale disk contents can't clobber fresh server data.
    private var hasFreshData = false
    /// The snapshot is read once per profile; later calls answer from memory.
    private var hydrated = false

    /// Bumped on every rebuild. Consumers (e.g. the trending hero) read this to
    /// skip recomputation when the index hasn't actually changed since their last
    /// run, so overlapping triggers don't repeat identical work.
    private(set) var generation = 0

    /// Where the snapshot lives. nil is the app's Caches directory; tests pass
    /// their own so they never touch the real snapshot.
    private let cacheDirectoryOverride: URL?

    init(cacheDirectory: URL? = nil) {
        cacheDirectoryOverride = cacheDirectory
    }

    /// Replace the index with `sections`, the whole set for the visible
    /// libraries, and notify observers. This is the authoritative path: it always
    /// wins over `hydrateFromDisk()`.
    ///
    /// Writes the sections named in `changed` and deletes the saved file of any
    /// section that is no longer in the set (a library hidden or removed).
    func replace(with sections: [Section], changed: Set<String>) {
        rebuild(from: sections, source: "replace")
        hasFreshData = true
        persist(sections.filter { changed.contains($0.key) }, keeping: Set(sections.map(\.key)))
    }

    /// The sections in memory, by section key, for the builder to compare with
    /// the server.
    func storedSections() -> [String: Section] {
        Dictionary(sections.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Populate the index from the saved snapshot. Local decode, so it runs at
    /// launch to make "do I own this?" answers available before the network
    /// check. Reads disk once; skips if fresh network data already arrived.
    /// Returns the number of entries in the index (0 = miss / skipped).
    @discardableResult
    func hydrateFromDisk() -> Int {
        guard !hasFreshData else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk skipped: fresh network data already present")
            return 0
        }
        guard !hydrated else { return entryCount }
        hydrated = true
        Self.removeLegacySnapshots()
        let loaded = Self.loadFromDisk(in: cacheDirectory)
        guard !loaded.isEmpty else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk miss: no valid cache on disk")
            return 0
        }
        rebuild(from: loaded, source: "hydrateFromDisk")
        return entryCount
    }

    private var entryCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }

    /// Shared ingest + notify used by both `replace` and `hydrateFromDisk`.
    private func rebuild(from sections: [Section], source: String) {
        self.sections = sections
        byTypedTmdbId.removeAll(keepingCapacity: true)
        byGuid.removeAll(keepingCapacity: true)

        for (sectionIndex, section) in sections.enumerated() {
            for (entryIndex, entry) in section.entries.enumerated() {
                ingest(entry, at: sectionIndex << 32 | entryIndex)
            }
        }
        generation += 1

        let typedCount = byTypedTmdbId.count
        let guidCount = byGuid.count
        let count = entryCount
        guidIndexLog.info("[Hero] LibraryGUIDIndex.\(source, privacy: .public): ingested \(count, privacy: .public) items -> typedTmdbCount=\(typedCount, privacy: .public), guidCount=\(guidCount, privacy: .public)")
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
        return byTypedTmdbId[TypedKey(type: plexType, tmdbId: tmdbId)].map(metadata(at:))
    }

    func lookup(guid: String) -> PlexMetadata? {
        byGuid[guid].map(metadata(at:))
    }

    func contains(guid: String) -> Bool {
        byGuid[guid] != nil
    }

    private func metadata(at position: Int) -> PlexMetadata {
        sections[position >> 32].entries[position & 0xFFFF_FFFF].metadata
    }

    // MARK: - Title search (Search suggestions)

    private struct TitleRecord: Sendable {
        let position: Int
        let keys: TitleMatcher.Keys
        let tmdbId: Int?
        let isMovie: Bool
    }

    /// Match keys for every title, built on the first search after a rebuild.
    private var titleRecords: [TitleRecord] = []
    private var titleRecordsGeneration = -1

    struct TitleHit: Sendable {
        let metadata: PlexMetadata
        let tmdbId: Int?
        let match: TitleMatch
    }

    /// The titles answering `query`, best first, at most `limit`. A title in
    /// two libraries (a 4K and a 1080p copy) counts once.
    func titleMatches(_ query: TitleMatcher.Query, limit: Int) -> [TitleHit] {
        if titleRecordsGeneration != generation {
            titleRecords = sections.enumerated().flatMap { sectionIndex, section in
                section.entries.enumerated().compactMap { entryIndex, entry -> TitleRecord? in
                    guard let title = entry.title, entry.type == "movie" || entry.type == "show" else { return nil }
                    return TitleRecord(
                        position: sectionIndex << 32 | entryIndex,
                        keys: TitleMatcher.Keys(title: title),
                        tmdbId: entry.externalGuids.lazy.compactMap(Self.tmdbId(from:)).first,
                        isMovie: entry.type == "movie")
                }
            }
            titleRecordsGeneration = generation
        }
        var hits: [(record: TitleRecord, match: TitleMatch)] = []
        for record in titleRecords {
            if let match = TitleMatcher.match(record.keys, query) { hits.append((record, match)) }
        }
        // The closer title first within a kind of match: "Alien" before
        // "Alien: Romulus" for "alien".
        hits.sort {
            $0.match.rank != $1.match.rank
                ? $0.match.rank < $1.match.rank
                : $0.record.keys.full.count < $1.record.keys.full.count
        }
        var seen = Set<String>()
        var out: [TitleHit] = []
        for hit in hits {
            let id = hit.record.tmdbId.map { "\(hit.record.isMovie ? "movie" : "tv"):\($0)" }
                ?? hit.record.keys.full
            guard seen.insert(id).inserted else { continue }
            out.append(TitleHit(metadata: metadata(at: hit.record.position),
                                tmdbId: hit.record.tmdbId, match: hit.match))
            if out.count == limit { break }
        }
        return out
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
    /// 3: one file per section, written in chunks.
    private static let cacheVersion = 3

    /// Entries per line of a section file. Encoding a 100,000-title section in
    /// one `JSONEncoder` call holds the whole JSON tree at once; a chunk at a
    /// time holds one chunk.
    private static let chunkSize = 2000

    /// A section file is this header as its first line, then one JSON array of
    /// up to `chunkSize` entries per line. JSONEncoder never writes a raw
    /// newline inside a value, so lines split cleanly.
    private struct DiskHeader: Codable {
        let version: Int
        let key: String
        let serverID: String?
        let signature: String?
        let fetchedAt: Date
        let count: Int
    }

    private var cacheDirectory: URL? {
        if let cacheDirectoryOverride { return cacheDirectoryOverride }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        // One snapshot per Home profile: what is "in your library" depends on who looks.
        let owner = UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey)
        return caches.appendingPathComponent("LibraryGUIDIndex", isDirectory: true)
            .appendingPathComponent(owner == 0 ? "default" : "\(owner)", isDirectory: true)
    }

    /// Another profile owns the content now: drop the previous one's answers
    /// and take this profile's last snapshot.
    func profileChanged() {
        hasFreshData = false
        hydrated = true
        rebuild(from: Self.loadFromDisk(in: cacheDirectory), source: "profileChanged")
    }

    /// Write `sections` and delete the files of sections not in `keeping`.
    /// Fire-and-forget on a background task so the encode + write never
    /// serializes behind other actor work or the caller's critical path.
    private func persist(_ sections: [Section], keeping: Set<String>) {
        guard let directory = cacheDirectory else { return }
        // Chained, so two passes' writes and deletions land in the order made.
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                for section in sections {
                    try Self.write(section, to: Self.fileURL(for: section.key, in: directory))
                    guidIndexLog.info("[GUIDIndex] persisted section \(section.key, privacy: .public): \(section.entries.count, privacy: .public) entries")
                }
                let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "ndjson" {
                    let key = String(file.deletingPathExtension().lastPathComponent.dropFirst("section-".count))
                    if !keeping.contains(key) { try? fm.removeItem(at: file) }
                }
            } catch {
                guidIndexLog.error("[GUIDIndex] persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var pendingWrite: Task<Void, Never>?

    /// Waits for every write `replace` has started.
    func waitForPendingWrites() async {
        await pendingWrite?.value
    }

    private static func fileURL(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent("section-\(key).ndjson")
    }

    private static func write(_ section: Section, to url: URL) throws {
        let encoder = JSONEncoder()
        let newline = Data([0x0A])
        let temporary = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        fm.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            let header = DiskHeader(version: cacheVersion, key: section.key, serverID: section.serverID,
                                    signature: section.signature, fetchedAt: section.fetchedAt,
                                    count: section.entries.count)
            try handle.write(contentsOf: encoder.encode(header) + newline)
            var start = 0
            while start < section.entries.count {
                let end = min(start + chunkSize, section.entries.count)
                try handle.write(contentsOf: encoder.encode(Array(section.entries[start..<end])) + newline)
                start = end
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temporary)
            throw error
        }
        _ = try fm.replaceItemAt(url, withItemAt: temporary)
    }

    /// Every valid section file in `directory`. A file of another version, a
    /// different key, or fewer entries than its header promises (a write cut
    /// short) is skipped, so its section is read from the server again.
    private static func loadFromDisk(in directory: URL?) -> [Section] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        var sections: [Section] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "ndjson" {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            guard let first = lines.first,
                  let header = try? decoder.decode(DiskHeader.self, from: first),
                  header.version == cacheVersion,
                  file.lastPathComponent == fileURL(for: header.key, in: directory).lastPathComponent
            else { continue }
            var entries: [Entry] = []
            entries.reserveCapacity(header.count)
            var valid = true
            for line in lines.dropFirst() {
                guard let chunk = try? decoder.decode([Entry].self, from: line) else { valid = false; break }
                entries.append(contentsOf: chunk)
            }
            guard valid, entries.count == header.count else {
                guidIndexLog.error("[GUIDIndex] section \(header.key, privacy: .public) on disk is incomplete; ignoring")
                continue
            }
            sections.append(Section(key: header.key, serverID: header.serverID, signature: header.signature,
                                    fetchedAt: header.fetchedAt, entries: entries))
        }
        return sections
    }

    /// The one-file snapshots of versions 1 and 2, superseded by the section
    /// directory.
    private static func removeLegacySnapshots() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix("library-guid-index") && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

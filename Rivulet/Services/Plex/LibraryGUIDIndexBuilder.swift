// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryGUIDIndexBuilder.swift
//  Rivulet
//
//  Reads the selected server's video libraries into LibraryGUIDIndex, one
//  section at a time, and reuses every section the server reports unchanged.
//
//  Two things a large server does that a small one never shows:
//    • A 5,000-show page can take longer than the request timeout. Measured on
//      a server with 33,000-show libraries: the first page of two TV libraries
//      timed out (-1001) on every launch, the build was never complete, and the
//      index was never saved, so every launch read 177,000 titles again.
//    • Reading the whole index is ~35 pages and minutes of server time, which a
//      launch should not pay when nothing changed.
//
//  So TV libraries start on smaller pages, a timed-out page is retried on a
//  smaller one, each section is saved on its own, and a launch reads only the
//  sections whose signature moved.
//

import Foundation
import os.log
import Sentry

nonisolated private let builderLog = Logger(subsystem: "com.rivulet.app", category: "LibraryIndex")

nonisolated struct LibraryGUIDIndexBuilder: Sendable {
    struct Library: Sendable, Equatable {
        let key: String
        let type: String?
    }

    struct Page: Sendable {
        let items: [PlexMetadata]
        let totalSize: Int?
    }

    struct Result: Sendable {
        /// The visible libraries' sections in order: fresh, reused, or the last
        /// saved copy of one that failed.
        var sections: [LibraryGUIDIndex.Section]
        /// Sections read from the server this pass, which need saving.
        var changed: Set<String>
        /// Libraries that could not be read this pass.
        var failed: [Library]
    }

    /// One page of a section's listing, with GUIDs.
    var fetchPage: @Sendable (_ section: String, _ start: Int, _ size: Int) async throws -> Page
    /// The section's current signature (see `signature(totalSize:newest:)`).
    var fetchSignature: @Sendable (_ section: String) async throws -> String
    var serverID: String?
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// TV libraries are slower per item: the server computes each show's
    /// episode counts. 5,000 shows outran the 30 s request timeout; 1,000 did not.
    static func firstPageSize(for type: String?) -> Int {
        type == "show" ? 1000 : 5000
    }
    static let minimumPageSize = 250
    /// The first try and two retries.
    static let attemptsPerPage = 3
    /// A saved section is reused for at most this long, even when its signature
    /// still matches, so edits the signature cannot see (a re-match, new
    /// artwork, watch state) are picked up daily.
    static let maxSectionAge: TimeInterval = 24 * 60 * 60
    /// Waits before each in-session retry of the libraries that failed.
    static let laterRetryDelays: [Duration] = [.seconds(120), .seconds(240)]

    /// A section's identity for "has anything been added or removed": its item
    /// count and its newest-added item. A deletion moves the count, an addition
    /// moves both.
    static func signature(totalSize: Int?, newest: PlexMetadata?) -> String {
        "\(totalSize ?? -1)|\(newest?.ratingKey ?? "-")|\(newest?.addedAt ?? 0)|\(newest?.updatedAt ?? 0)"
    }

    // MARK: - Build

    /// Reads, or reuses, every library in `libraries`.
    func build(libraries: [Library], stored: [String: LibraryGUIDIndex.Section]) async -> Result {
        var result = Result(sections: [], changed: [], failed: [])
        for library in libraries {
            if Task.isCancelled { break }
            // nil when the check itself failed.
            let signature = try? await fetchSignature(library.key)
            let saved = stored[library.key].flatMap { $0.serverID == serverID ? $0 : nil }
            if let saved, isReusable(saved, currentSignature: signature) {
                result.sections.append(saved)
                continue
            }
            if let fresh = await fetchSection(library, signature: signature) {
                result.sections.append(fresh)
                result.changed.insert(library.key)
            } else {
                result.failed.append(library)
                // An older copy beats a hole: the titles it lists still exist
                // more often than not, and the next pass reads the section again.
                if let saved { result.sections.append(saved) }
            }
        }
        return result
    }

    /// A saved section stands when the server reports the same signature and it
    /// is under a day old, or when the server could not be asked at all.
    func isReusable(_ saved: LibraryGUIDIndex.Section, currentSignature: String?) -> Bool {
        guard let currentSignature else { return true }
        return saved.signature == currentSignature
            && now().timeIntervalSince(saved.fetchedAt) < Self.maxSectionAge
    }

    /// Every page of one section, or nil if a page failed all its attempts.
    /// A timeout halves the page size for the retry and for the rest of the
    /// section; other errors retry at the same size.
    func fetchSection(_ library: Library, signature: String?) async -> LibraryGUIDIndex.Section? {
        var entries: [LibraryGUIDIndex.Entry] = []
        var start = 0
        var size = Self.firstPageSize(for: library.type)
        var attempt = 0
        while true {
            do {
                let page = try await fetchPage(library.key, start, size)
                entries.append(contentsOf: page.items.compactMap(LibraryGUIDIndex.Entry.init))
                start += page.items.count
                attempt = 0
                // An empty page or reaching the reported total is the only way
                // out that means the section was seen in full.
                if page.items.isEmpty || start >= (page.totalSize ?? 0) { break }
            } catch {
                if error is CancellationError || Task.isCancelled { return nil }
                attempt += 1
                guard attempt < Self.attemptsPerPage else {
                    builderLog.error("[GUIDIndex] section \(library.key, privacy: .public) failed at offset \(start) after \(attempt) attempts: \(error.localizedDescription, privacy: .public)")
                    let crumb = Breadcrumb(level: .error, category: "guid_index")
                    crumb.message = "Library GUID fetch failed"
                    crumb.data = ["section": library.key, "offset": start, "page_size": size,
                                  "error": error.localizedDescription]
                    SentryBridge.addBreadcrumb(crumb)
                    return nil
                }
                if Self.isTimeout(error) { size = max(Self.minimumPageSize, size / 2) }
                builderLog.info("[GUIDIndex] section \(library.key, privacy: .public) offset \(start): retry \(attempt) at \(size) per page")
                await sleep(.seconds(2 * attempt))
            }
        }
        return LibraryGUIDIndex.Section(key: library.key, serverID: serverID, signature: signature,
                                        fetchedAt: now(), entries: entries)
    }

    static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code == .timedOut }
        if case PlexAPIError.networkError(let underlying) = error { return isTimeout(underlying) }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    // MARK: - Run

    /// Hydrate, check every library against the server, save what changed, then
    /// retry the libraries that failed on their own, later in the session.
    /// `isCurrent` is asked before each write: false means the account or
    /// profile changed while this ran, and the result is not that one's.
    func run(libraries: [Library], into index: LibraryGUIDIndex,
             isCurrent: @Sendable () async -> Bool) async {
        // Nothing to compare against: writing would delete every saved section.
        guard !libraries.isEmpty else { return }
        await index.hydrateFromDisk()
        var stored = await index.storedSections()
        var result = await build(libraries: libraries, stored: stored)
        guard await isCurrent() else { return }
        await apply(result, stored: stored, to: index, pass: 0)

        for (retry, delay) in Self.laterRetryDelays.enumerated() where !result.failed.isEmpty {
            await sleep(delay)
            guard !Task.isCancelled, await isCurrent() else { return }
            stored = await index.storedSections()
            let again = await build(libraries: result.failed, stored: stored)
            guard await isCurrent() else { return }
            // Merge the retried sections back in visible-library order.
            let retried = Dictionary(again.sections.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let current = Dictionary(result.sections.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            result = Result(
                sections: libraries.compactMap { retried[$0.key] ?? current[$0.key] },
                changed: again.changed,
                failed: again.failed
            )
            await apply(result, stored: stored, to: index, pass: retry + 1)
        }
    }

    private func apply(_ result: Result, stored: [String: LibraryGUIDIndex.Section],
                       to index: LibraryGUIDIndex, pass: Int) async {
        let entryCount = result.sections.reduce(0) { $0 + $1.entries.count }
        builderLog.info("[GUIDIndex] pass \(pass): \(result.changed.count) sections read, \(result.sections.count - result.changed.count) reused, \(result.failed.count) failed, \(entryCount) titles")
        let crumb = Breadcrumb(level: .info, category: "guid_index")
        crumb.message = "Library GUID index rebuilt"
        crumb.data = ["pass": pass, "read": result.changed.count, "failed_sections": result.failed.count,
                      "items": entryCount]
        SentryBridge.addBreadcrumb(crumb)

        // Same sections as memory already holds: nothing to rebuild or save.
        let sameSet = Set(result.sections.map(\.key)) == Set(stored.keys)
        if result.changed.isEmpty && sameSet { return }
        await index.replace(with: result.sections, changed: result.changed)
    }
}

extension LibraryGUIDIndexBuilder {
    /// The builder against the selected Plex server.
    static func plex(serverURL: String, token: String, serverID: String?) -> LibraryGUIDIndexBuilder {
        LibraryGUIDIndexBuilder(
            fetchPage: { section, start, size in
                let page = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                    serverURL: serverURL, authToken: token, sectionId: section,
                    start: start, size: size, includeGuids: true
                )
                return Page(items: page.items, totalSize: page.totalSize)
            },
            fetchSignature: { section in
                let page = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                    serverURL: serverURL, authToken: token, sectionId: section,
                    start: 0, size: 1, sort: "addedAt:desc"
                )
                return signature(totalSize: page.totalSize, newest: page.items.first)
            },
            serverID: serverID
        )
    }
}

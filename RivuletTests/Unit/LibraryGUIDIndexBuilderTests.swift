// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryGUIDIndexBuilderTests.swift
//  RivuletTests

import XCTest
@testable import Rivulet

final class LibraryGUIDIndexBuilderTests: XCTestCase {

    /// A fake server: sections of numbered titles, with scripted failures.
    private final class Server: @unchecked Sendable {
        let lock = NSLock()
        var sizes: [String: Int] = [:]
        var types: [String: String] = [:]
        /// Requests (section, start, size) that throw, consumed in order.
        var failures: [(section: String, error: Error)] = []
        var signatureFails = Set<String>()
        var requests: [(section: String, start: Int, size: Int)] = []
        var signatureRequests: [String] = []

        func page(_ section: String, _ start: Int, _ size: Int) throws -> LibraryGUIDIndexBuilder.Page {
            lock.lock(); defer { lock.unlock() }
            requests.append((section, start, size))
            if let i = failures.firstIndex(where: { $0.section == section }) {
                throw failures.remove(at: i).error
            }
            let total = sizes[section] ?? 0
            let items = (start..<min(start + size, total)).map { i -> PlexMetadata in
                var item = PlexMetadata(ratingKey: "\(section)-\(i)", type: types[section] ?? "movie", title: "T\(i)")
                item.Guid = [PlexGuid(id: "imdb://\(section)-\(i)")]
                return item
            }
            return .init(items: items, totalSize: total)
        }

        func signature(_ section: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            signatureRequests.append(section)
            if signatureFails.contains(section) { throw URLError(.notConnectedToInternet) }
            return "\(sizes[section] ?? 0)"
        }

        func pageRequests(for section: String) -> [(start: Int, size: Int)] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0.section == section }.map { ($0.start, $0.size) }
        }
    }

    private var server: Server!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        server = Server()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryGUIDIndexBuilderTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func builder(now: Date = Date()) -> LibraryGUIDIndexBuilder {
        let server = server!
        return LibraryGUIDIndexBuilder(
            fetchPage: { try server.page($0, $1, $2) },
            fetchSignature: { try server.signature($0) },
            serverID: "server",
            now: { now },
            sleep: { _ in }
        )
    }

    private func saved(_ key: String, count: Int, signature: String?, fetchedAt: Date = Date(),
                       serverID: String? = "server") -> LibraryGUIDIndex.Section {
        let entries = (0..<count).compactMap { i -> LibraryGUIDIndex.Entry? in
            var item = PlexMetadata(ratingKey: "old-\(i)", type: "movie", title: "Old")
            item.Guid = [PlexGuid(id: "imdb://old-\(key)-\(i)")]
            return LibraryGUIDIndex.Entry(item)
        }
        return .init(key: key, serverID: serverID, signature: signature, fetchedAt: fetchedAt, entries: entries)
    }

    // MARK: - Paging

    func testTVLibrariesStartOnSmallerPages() async {
        server.sizes = ["6": 2500, "9": 2500]
        server.types = ["6": "show"]
        let result = await builder().build(
            libraries: [.init(key: "6", type: "show"), .init(key: "9", type: "movie")], stored: [:])

        XCTAssertEqual(server.pageRequests(for: "6").map(\.size), [1000, 1000, 1000])
        XCTAssertEqual(server.pageRequests(for: "9").map(\.size), [5000])
        XCTAssertEqual(result.sections.map { $0.entries.count }, [2500, 2500])
    }

    func testATimeoutRetriesTheSameOffsetOnHalfThePage() async {
        server.sizes = ["15": 1800]
        server.failures = [("15", URLError(.timedOut))]
        let result = await builder().build(libraries: [.init(key: "15", type: "show")], stored: [:])

        let requests = server.pageRequests(for: "15")
        XCTAssertEqual(requests.map(\.start), [0, 0, 500, 1000, 1500])
        XCTAssertEqual(requests.map(\.size), [1000, 500, 500, 500, 500], "the smaller page holds for the rest of the section")
        XCTAssertEqual(result.sections.first?.entries.count, 1800)
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testOtherErrorsRetryAtTheSameSize() async {
        server.sizes = ["9": 10]
        server.failures = [("9", URLError(.networkConnectionLost))]
        _ = await builder().build(libraries: [.init(key: "9", type: "movie")], stored: [:])

        XCTAssertEqual(server.pageRequests(for: "9").map(\.size), [5000, 5000])
    }

    func testAPageFailingEveryAttemptFailsOnlyItsSection() async {
        server.sizes = ["6": 100, "9": 100]
        server.failures = Array(repeating: ("6", URLError(.timedOut)), count: 3)
        let result = await builder().build(
            libraries: [.init(key: "6", type: "show"), .init(key: "9", type: "movie")], stored: [:])

        XCTAssertEqual(server.pageRequests(for: "6").map(\.size), [1000, 500, 250])
        XCTAssertEqual(result.failed.map(\.key), ["6"])
        XCTAssertEqual(result.sections.map(\.key), ["9"], "a half-read section is never kept")
        XCTAssertEqual(result.changed, ["9"])
    }

    func testAFailedSectionKeepsItsSavedCopy() async {
        server.sizes = ["6": 100]
        server.failures = Array(repeating: ("6", URLError(.timedOut)), count: 3)
        let result = await builder().build(
            libraries: [.init(key: "6", type: "show")],
            stored: ["6": saved("6", count: 3, signature: "stale")])

        XCTAssertEqual(result.failed.map(\.key), ["6"])
        XCTAssertEqual(result.sections.first?.entries.count, 3)
        XCTAssertTrue(result.changed.isEmpty, "the old copy is not written again")
    }

    // MARK: - Reuse

    func testAnUnchangedSectionIsNotDownloaded() async {
        server.sizes = ["9": 100]
        let result = await builder().build(
            libraries: [.init(key: "9", type: "movie")], stored: ["9": saved("9", count: 3, signature: "100")])

        XCTAssertTrue(server.pageRequests(for: "9").isEmpty)
        XCTAssertEqual(server.signatureRequests, ["9"])
        XCTAssertEqual(result.sections.first?.entries.count, 3)
        XCTAssertTrue(result.changed.isEmpty)
    }

    func testAChangedSignatureReadsTheSectionAgain() async {
        server.sizes = ["9": 101]
        let result = await builder().build(
            libraries: [.init(key: "9", type: "movie")], stored: ["9": saved("9", count: 3, signature: "100")])

        XCTAssertEqual(result.sections.first?.entries.count, 101)
        XCTAssertEqual(result.sections.first?.signature, "101")
        XCTAssertEqual(result.changed, ["9"])
    }

    func testASectionOlderThanADayIsReadAgain() async {
        server.sizes = ["9": 100]
        let now = Date()
        let old = saved("9", count: 3, signature: "100", fetchedAt: now.addingTimeInterval(-25 * 3600))
        let result = await builder(now: now).build(libraries: [.init(key: "9", type: "movie")], stored: ["9": old])

        XCTAssertEqual(result.changed, ["9"])
    }

    func testAnUnreachableSignatureKeepsTheSavedSection() async {
        server.sizes = ["9": 100]
        server.signatureFails = ["9"]
        let now = Date()
        let old = saved("9", count: 3, signature: "100", fetchedAt: now.addingTimeInterval(-25 * 3600))
        let result = await builder(now: now).build(libraries: [.init(key: "9", type: "movie")], stored: ["9": old])

        XCTAssertTrue(server.pageRequests(for: "9").isEmpty)
        XCTAssertEqual(result.sections.first?.entries.count, 3)
    }

    func testASectionFromAnotherServerIsNotReused() async {
        server.sizes = ["9": 100]
        let other = saved("9", count: 3, signature: "100", serverID: "other")
        let result = await builder().build(libraries: [.init(key: "9", type: "movie")], stored: ["9": other])

        XCTAssertEqual(result.sections.first?.entries.count, 100)
        XCTAssertEqual(result.sections.first?.serverID, "server")
    }

    // MARK: - Run

    func testRunSavesWhatLoadedAndRetriesOnlyTheFailedLibraryLater() async {
        server.sizes = ["6": 50, "9": 70]
        server.types = ["6": "show"]
        server.failures = Array(repeating: ("6", URLError(.timedOut)), count: 3)
        let index = LibraryGUIDIndex(cacheDirectory: directory)

        await builder().run(libraries: [.init(key: "6", type: "show"), .init(key: "9", type: "movie")],
                            into: index, isCurrent: { true })
        await index.waitForPendingWrites()

        XCTAssertEqual(server.pageRequests(for: "9").count, 1, "the later pass does not read 9 again")
        XCTAssertEqual(server.pageRequests(for: "6").count, 4, "three failed attempts, then one later pass")
        let stored = await index.storedSections()
        XCTAssertEqual(stored["6"]?.entries.count, 50)
        XCTAssertEqual(stored["9"]?.entries.count, 70)

        // A second launch: both sections come from disk and nothing is downloaded.
        let relaunch = LibraryGUIDIndex(cacheDirectory: directory)
        let before = server.requests.count
        await builder().run(libraries: [.init(key: "6", type: "show"), .init(key: "9", type: "movie")],
                            into: relaunch, isCurrent: { true })
        XCTAssertEqual(server.requests.count, before)
        let match = await relaunch.lookup(guid: "imdb://6-49")
        XCTAssertEqual(match?.ratingKey, "6-49")
    }

    func testRunWritesNothingWhenTheAccountChanged() async {
        server.sizes = ["9": 10]
        let index = LibraryGUIDIndex(cacheDirectory: directory)
        await builder().run(libraries: [.init(key: "9", type: "movie")], into: index, isCurrent: { false })

        let isEmpty = await index.isEmpty
        XCTAssertTrue(isEmpty)
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The disk cache belongs to the Home user whose token wrote it: once content
/// changes hands, nothing the previous user cached is read back.
final class CacheManagerProfileOwnerTests: XCTestCase {

    func test_cacheWrittenForOneUser_isNotReadForAnother() async throws {
        // Own suite and directory: the test host's real defaults and cache stay untouched.
        let suite = "CacheManagerProfileOwnerTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = CacheManager(directory: directory, defaults: defaults)

        defaults.set(7, forKey: PlexProfileSession.contentUserIDKey)
        await cache.cacheHubs([])
        let own = await cache.getCachedHubs()
        XCTAssertNotNil(own)

        defaults.set(8, forKey: PlexProfileSession.contentUserIDKey)
        let foreign = await cache.getCachedHubs()
        XCTAssertNil(foreign)

        // The new owner's writes read back, so the purge ran once and not on every read.
        await cache.cacheHubs([])
        let rewritten = await cache.getCachedHubs()
        XCTAssertNotNil(rewritten)
    }
}

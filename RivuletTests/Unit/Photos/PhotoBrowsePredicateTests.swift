// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PhotoBrowsePredicateTests: XCTestCase {
    private func library(_ key: String, _ type: String) -> PlexLibrary {
        PlexLibrary(key: key, type: type, title: key, agent: nil, scanner: nil, language: nil, uuid: key,
                    updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
    }

    func test_photoSection_hasABrowseSurface() {
        XCTAssertTrue(library("p", "photo").isPhotoLibrary)
        XCTAssertTrue(library("p", "photo").hasBrowseSurface)
        XCTAssertFalse(library("m", "movie").isPhotoLibrary)
        XCTAssertFalse(library("x", "clip").hasBrowseSurface)
    }

    /// The sidebar lists a photo library; Home rows, hubs and prefetch never see it.
    func test_photoSection_isInTheSidebar_andOutOfHome() {
        let store = PlexDataStore.shared
        let mgr = LibrarySettingsManager.shared
        let saved = (store.libraries, mgr.hiddenLibraryKeys, mgr.libraryOrder)
        defer { (store.libraries, mgr.hiddenLibraryKeys, mgr.libraryOrder) = saved }
        mgr.libraryOrder = []
        mgr.hiddenLibraryKeys = []
        store.libraries = [library("m", "movie"), library("a", "artist"), library("p", "photo")]

        XCTAssertEqual(store.visibleSidebarLibraries.map(\.key), ["m", "a", "p"])
        XCTAssertEqual(store.visibleMediaLibraries.map(\.key), ["m", "a"])
        XCTAssertEqual(store.librariesPinnedToHome.map(\.key), ["m", "a"])

        mgr.hiddenLibraryKeys = ["p"]
        XCTAssertEqual(store.visibleSidebarLibraries.map(\.key), ["m", "a"], "the Settings toggle hides it")
    }

    func test_sidebarIcon() {
        XCTAssertEqual(ShellSidebarModel.icon(forLibraryType: "photo"), "photo.fill")
        XCTAssertEqual(ShellSidebarModel.icon(forLibraryKind: .photos), "photo.fill")
    }

    func test_jellyfin_photoLibrariesAreBrowsable() {
        XCTAssertTrue(JellyfinDataStore.browsableKinds.contains(.photos))
        XCTAssertFalse(JellyfinDataStore.browsableKinds.contains(.music))
    }

    func test_plexProvider_isFoundAsAPhotoProviderByCast() {
        let provider: any MediaProvider = PlexProvider(machineIdentifier: "abc", displayName: "s",
                                                       serverURL: "http://s", authToken: "t")
        XCTAssertNotNil(provider as? any PhotoProvider)
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerPreferencesTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class ServerPreferencesTests: XCTestCase {
    private let keys = ["plexServerOrder", "plexServersDisabled", "plexLastWatchedServer",
                        "plexLastWatchedServer.order", "plexMainServerMachineId"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    /// Never ordered: the main server first, the rest as given.
    func test_unorderedPutsMainFirst() {
        ServerPreferences.setMainMachineId("main-server")
        XCTAssertEqual(ServerPreferences.sorted(["shared-server", "main-server", "other-server"], by: { $0 }),
                       ["main-server", "shared-server", "other-server"])
    }

    func test_moveStoresTheShownOrder() {
        ServerPreferences.setMainMachineId("main-server")
        let shown = ["main-server", "shared-server", "other-server"]
        ServerPreferences.move("other-server", up: true, among: shown)
        XCTAssertEqual(ServerPreferences.sorted(shown, by: { $0 }), ["main-server", "other-server", "shared-server"])
        ServerPreferences.move("other-server", up: true, among: shown)
        XCTAssertEqual(ServerPreferences.sorted(shown, by: { $0 }), ["other-server", "main-server", "shared-server"])
    }

    /// The main server can't be turned off; the others can.
    func test_mainServerStaysOn() {
        ServerPreferences.setMainMachineId("main-server")
        ServerPreferences.setEnabled("main-server", false)
        ServerPreferences.setEnabled("shared-server", false)
        XCTAssertTrue(ServerPreferences.isEnabled("main-server"))
        XCTAssertFalse(ServerPreferences.isEnabled("shared-server"))
        ServerPreferences.setEnabled("shared-server", true)
        XCTAssertTrue(ServerPreferences.isEnabled("shared-server"))
    }

    /// An episode play remembers its show too, so the show page opens there.
    func test_recordWatchedCoversEpisodeAndShow() {
        ServerPreferences.recordWatched(guids: ["plex://episode/1", "plex://show/9", nil], machineId: "shared-server")
        XCTAssertEqual(ServerPreferences.lastWatchedServer(forGuid: "plex://episode/1"), "shared-server")
        XCTAssertEqual(ServerPreferences.lastWatchedServer(forGuid: "plex://show/9"), "shared-server")
        ServerPreferences.recordWatched(guids: ["plex://show/9"], machineId: "other-server")
        XCTAssertEqual(ServerPreferences.lastWatchedServer(forGuid: "plex://show/9"), "other-server")
        // Only Plex guids are keys.
        ServerPreferences.recordWatched(guids: ["tmdb://5"], machineId: "other-server")
        XCTAssertNil(ServerPreferences.lastWatchedServer(forGuid: "tmdb://5"))
    }
}

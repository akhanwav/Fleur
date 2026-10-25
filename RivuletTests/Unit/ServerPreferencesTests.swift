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
        ServerPreferences.setMainMachineId("diamond")
        XCTAssertEqual(ServerPreferences.sorted(["sesame", "diamond", "alpha"], by: { $0 }),
                       ["diamond", "sesame", "alpha"])
    }

    func test_moveStoresTheShownOrder() {
        ServerPreferences.setMainMachineId("diamond")
        let shown = ["diamond", "sesame", "alpha"]
        ServerPreferences.move("alpha", up: true, among: shown)
        XCTAssertEqual(ServerPreferences.sorted(shown, by: { $0 }), ["diamond", "alpha", "sesame"])
        ServerPreferences.move("alpha", up: true, among: shown)
        XCTAssertEqual(ServerPreferences.sorted(shown, by: { $0 }), ["alpha", "diamond", "sesame"])
    }

    /// The main server can't be turned off; the others can.
    func test_mainServerStaysOn() {
        ServerPreferences.setMainMachineId("diamond")
        ServerPreferences.setEnabled("diamond", false)
        ServerPreferences.setEnabled("sesame", false)
        XCTAssertTrue(ServerPreferences.isEnabled("diamond"))
        XCTAssertFalse(ServerPreferences.isEnabled("sesame"))
        ServerPreferences.setEnabled("sesame", true)
        XCTAssertTrue(ServerPreferences.isEnabled("sesame"))
    }

    /// An episode play remembers its show too, so the show page opens there.
    func test_recordWatchedCoversEpisodeAndShow() {
        ServerPreferences.recordWatched(guids: ["plex://episode/1", "plex://show/9", nil], machineId: "sesame")
        XCTAssertEqual(ServerPreferences.lastWatchedServer(forGuid: "plex://episode/1"), "sesame")
        XCTAssertEqual(ServerPreferences.lastWatchedServer(forGuid: "plex://show/9"), "sesame")
        ServerPreferences.recordWatched(guids: ["plex://show/9"], machineId: "alpha")
        XCTAssertEqual(ServerPreferences.lastWatchedServer(forGuid: "plex://show/9"), "alpha")
        // Only Plex guids are keys.
        ServerPreferences.recordWatched(guids: ["tmdb://5"], machineId: "alpha")
        XCTAssertNil(ServerPreferences.lastWatchedServer(forGuid: "tmdb://5"))
    }
}

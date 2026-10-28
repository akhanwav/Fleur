// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Which servers a cross-server lookup asks, and what it may remember.
final class ServerLookupTests: XCTestCase {

    private typealias Checker = OtherServersAvailabilityChecker

    private func server(_ id: String, main: Bool = false) -> Checker.Server {
        Checker.Server(machineId: id, name: id, serverURL: "https://\(id)", token: "t-\(id)", isMain: main)
    }

    private func copy(_ server: String, _ key: String) -> Checker.ServerCopy {
        Checker.ServerCopy(serverName: server, serverURL: "https://\(server)", token: "t", ratingKey: key,
                           machineId: server)
    }

    // MARK: - Servers asked

    func test_account_asksEveryServer() {
        let servers = [server("main", main: true), server("shared"), server("second")]
        XCTAssertEqual(Checker.lookupServers(servers, accountContent: true).map(\.machineId), ["main", "shared", "second"])
    }

    /// A managed profile never reaches other servers with the owner's tokens.
    func test_otherHomeProfile_asksOnlyTheMainServer() {
        let servers = [server("main", main: true), server("shared"), server("second")]
        XCTAssertEqual(Checker.lookupServers(servers, accountContent: false).map(\.machineId), ["main"])
    }

    func test_singleServer_asksItself() {
        XCTAssertEqual(Checker.lookupServers([server("only", main: true)], accountContent: true).map(\.machineId), ["only"])
        XCTAssertEqual(Checker.lookupServers([server("only", main: true)], accountContent: false).map(\.machineId), ["only"])
    }

    /// Only shared servers: the signed-in one is main whoever owns it.
    func test_sharedServersOnly_mainIsTheSignedInShare() {
        let servers = [server("friend-a", main: true), server("friend-b")]
        XCTAssertEqual(Checker.lookupServers(servers, accountContent: true).count, 2)
        XCTAssertEqual(Checker.lookupServers(servers, accountContent: false).map(\.machineId), ["friend-a"])
    }

    // MARK: - What is remembered

    func test_everyServerAnswered_isCached() {
        let result = Checker.combine([[copy("b", "2")], [], [copy("a", "1")]])
        XCTAssertTrue(result.cacheable)
        XCTAssertEqual(result.copies.map(\.machineId), ["a", "b"])
    }

    /// An offline or slow server is unknown, not "has none": asked again next time.
    func test_aServerThatTimedOut_isNotCached() {
        let result = Checker.combine([[copy("a", "1")], nil])
        XCTAssertFalse(result.cacheable)
        XCTAssertEqual(result.copies.map(\.ratingKey), ["1"])
    }

    func test_noServerHasIt_isCachedAsNone() {
        let result = Checker.combine([[], []])
        XCTAssertTrue(result.cacheable)
        XCTAssertTrue(result.copies.isEmpty)
    }

    // MARK: - Kinds

    func test_everyGuidKindNamesItsPlexType() {
        XCTAssertEqual(Checker.plexType(of: "plex://movie/1"), "1")
        XCTAssertEqual(Checker.plexType(of: "plex://show/1"), "2")
        XCTAssertEqual(Checker.plexType(of: "plex://season/1"), "3")
        XCTAssertEqual(Checker.plexType(of: "plex://episode/1"), "4")
        XCTAssertNil(Checker.plexType(of: "local://1"))
    }
}

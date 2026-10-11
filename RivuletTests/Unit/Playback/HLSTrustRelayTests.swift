// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class HLSTrustRelayTests: XCTestCase {
    private let origin = URL(string: "https://192.168.50.5:32400/video/:/transcode/universal/start.m3u8?session=a")!

    func testLocalURLKeepsPathAndQueryForItsOwnOriginOnly() async throws {
        let started = await HLSTrustRelay.start(for: origin)
        let relay = try XCTUnwrap(started)
        let local = try XCTUnwrap(relay.localURL(for: origin))
        XCTAssertEqual(local.scheme, "http")
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertEqual(local.path, "/video/:/transcode/universal/start.m3u8")
        XCTAssertEqual(local.query, "session=a")
        XCTAssertNil(relay.localURL(for: URL(string: "https://192.168.50.6:32400/a.m3u8")!))
        XCTAssertNil(relay.localURL(for: URL(string: "https://192.168.50.5:324000/a.m3u8")!))
    }

    func testOriginRequestMapsTargetAndDropsHopHeaders() throws {
        let relay = try XCTUnwrap(HLSTrustRelay(origin: origin))
        let head = "GET /session/1/base/00001.ts?x=1 HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n"
            + "X-Plex-Token: t\r\nRange: bytes=0-99\r\nConnection: keep-alive\r\nAccept-Encoding: gzip"
        let request = try XCTUnwrap(relay.originRequest(head: head))
        XCTAssertEqual(request.url?.absoluteString, "https://192.168.50.5:32400/session/1/base/00001.ts?x=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-99")
        XCTAssertNil(request.value(forHTTPHeaderField: "Host"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Encoding"))
        XCTAssertNil(relay.originRequest(head: "GET http://evil.example/ HTTP/1.1"))
        XCTAssertNil(relay.originRequest(head: "garbage"))
    }
}

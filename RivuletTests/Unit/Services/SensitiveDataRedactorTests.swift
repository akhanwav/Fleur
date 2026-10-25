// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Sentry
import XCTest
@testable import Rivulet

/// A server address is the user's home IP (or a plex.direct name embedding
/// it), so it is scrubbed like a token.
final class SensitiveDataRedactorTests: XCTestCase {

    func test_redact_stripsServerAddressesFromProse() {
        let text = """
        Could not connect to https://192-168-1-20.0123abcd.plex.direct:32400/library/sections?X-Plex-Token=abc \
        (fallback http://10.0.0.2:32400/identity, relay 1-2-3-4.ffff.plex.direct, host 172.16.4.9)
        """

        let redacted = SensitiveDataRedactor.redact(text)

        for leak in ["192-168-1-20", "0123abcd", "10.0.0.2", "1-2-3-4", "172.16.4.9", "abc)"] {
            XCTAssertFalse(redacted.contains(leak), "leaked \(leak): \(redacted)")
        }
        XCTAssertTrue(redacted.contains("https://[server]:32400/library/sections?X-Plex-Token=[redacted]"))
        XCTAssertTrue(redacted.contains("http://[server]:32400/identity"))
    }

    func test_redact_keepsPublicHostsAndVersions() {
        let text = "GET https://clients.plex.tv/api/v2/user failed on PMS 1.43.4.10051"

        XCTAssertEqual(SensitiveDataRedactor.redact(text), text)
    }

    func test_redact_dropsUserinfo() {
        let redacted = SensitiveDataRedactor.redact("http://me:hunter2@iptv.example.com:8080/get.php")

        XCTAssertEqual(redacted, "http://[server]:8080/get.php")
    }

    func test_safeURLString_stripsHostAndXtreamAccount() {
        let long = URL(string: "http://iptv.example.com:8080/live/me/hunter2/1234.ts")!
        let short = URL(string: "http://iptv.example.com/me/hunter2/1234.m3u8")!
        let plex = URL(string: "https://10.0.0.2:32400/library/metadata/1234?X-Plex-Token=abc")!

        XCTAssertEqual(SensitiveDataRedactor.safeURLString(long), "http://[server]:8080/live/[redacted]/[redacted]/1234.ts")
        XCTAssertEqual(SensitiveDataRedactor.safeURLString(short), "http://[server]/[redacted]/[redacted]/1234.m3u8")
        XCTAssertEqual(SensitiveDataRedactor.safeURLString(plex), "https://[server]:32400/library/metadata/1234?[X-Plex-Token]")
    }

    func test_event_scrubsErrorUserInfoAndHostKeys() {
        let failing = "https://10.0.0.2:32400/hubs?X-Plex-Token=abc123"
        let event = Event(level: .error)
        event.context = ["user info": [NSURLErrorFailingURLStringErrorKey: failing]]
        let crumb = Breadcrumb(level: .warning, category: "plex_auth")
        crumb.data = ["host": "my-nas.local", "port": 32400]
        event.breadcrumbs = [crumb]

        let redacted = SentryEventRedaction.redact(event)

        let userInfo = redacted.context?["user info"]?[NSURLErrorFailingURLStringErrorKey] as? String
        XCTAssertEqual(userInfo, "https://[server]:32400/hubs?X-Plex-Token=[redacted]")
        XCTAssertEqual(redacted.breadcrumbs?.first?.data?["host"] as? String, "[server]")
        XCTAssertEqual(redacted.breadcrumbs?.first?.data?["port"] as? Int, 32400)
    }
}

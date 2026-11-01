import XCTest
@testable import Rivulet

/// Rate-limit backoff, the no-transcode rule for Dolby Vision without a
/// fallback layer, and the words a viewer reads when a server is down.
final class SentryWeeklyFixesTests: XCTestCase {

    func test_backoff_honoursRetryAfter_elseDoubles() {
        XCTAssertEqual(RateLimitBackoff.delay(retryAfter: "7", strikes: 3), 7)
        XCTAssertEqual(RateLimitBackoff.delay(retryAfter: "9999", strikes: 1), RateLimitBackoff.maxDelay)
        XCTAssertEqual(RateLimitBackoff.delay(retryAfter: nil, strikes: 1), 2)
        XCTAssertEqual(RateLimitBackoff.delay(retryAfter: nil, strikes: 3), 8)
        XCTAssertEqual(RateLimitBackoff.delay(retryAfter: nil, strikes: 20), 60)
    }

    func test_backoff_blocksTheHostUntilItAnswers() {
        let backoff = RateLimitBackoff()
        let now = Date()
        backoff.noteRateLimited(host: "plex.tv", retryAfter: "5", now: now)
        XCTAssertEqual(backoff.remainingWait(host: "plex.tv", now: now), 5, accuracy: 0.01)
        XCTAssertEqual(backoff.remainingWait(host: "plex.tv", now: now.addingTimeInterval(6)), 0)
        XCTAssertEqual(backoff.remainingWait(host: "other.example", now: now), 0)
        backoff.noteAnswered(host: "plex.tv")
        XCTAssertEqual(backoff.remainingWait(host: "plex.tv", now: now), 0)
    }

    func test_serverUnavailable_namesTheServerNotTheTranscode() {
        let down = PlayerError.loadFailed(PlayerError.serverUnavailableMessage)
        XCTAssertTrue(down.userFacingDescription.contains("unavailable"))
        XCTAssertTrue(PlayerError.loadFailed("HLS transcode session failed to start")
            .userFacingDescription.contains("too long"))
    }

    func test_only503CountsAsUnavailable() {
        let unavailable = PlayerError.engineFailure(kind: EngineFailureKind.sourceRateLimited,
                                                    message: "Origin answered HTTP 503 for the source")
        XCTAssertTrue(unavailable.isServiceUnavailable)
        XCTAssertTrue(unavailable.userFacingDescription.contains("unavailable"))
        let busy = PlayerError.engineFailure(kind: EngineFailureKind.sourceRateLimited,
                                             message: "Origin answered HTTP 429 for the source")
        XCTAssertFalse(busy.isServiceUnavailable)
        XCTAssertTrue(busy.userFacingDescription.contains("refusing"))
    }
}

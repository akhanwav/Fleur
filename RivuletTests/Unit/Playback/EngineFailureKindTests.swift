// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EngineFailureKindTests.swift
//  RivuletTests
//
//  RIVULET-19. The aether route classified its own failures by lowercasing the
//  engine's message and looking for "open input", "decoder", "stream info" and
//  friends. That fails twice: roughly half those messages are
//  AVPlayerItem.error.localizedDescription, so they arrive in the device's
//  language and match nothing on a non-English Apple TV, and the two failures
//  worth telling apart (an origin answering with an HTTP status vs a body that
//  genuinely is not media) produced the identical FFmpeg sentence until
//  AetherEngine 6.29.0 split them into `sourceRefused` / `sourceOpenFailed`.
//
//  AetherEngine now publishes a stable `PlaybackErrorKind` beside every error.
//  `DirectPlayFailureKind(engineKind:)` is the seam where that becomes a
//  routing decision, and it is a pure function, so unlike the view model that
//  calls it, it is reachable from a unit test.
//

import XCTest
@testable import Rivulet

final class EngineFailureKindTests: XCTestCase {

    // MARK: - The RIVULET-19 split

    /// The whole point of the change: these two used to be one bucket.
    func test_refusedAndUnreadable_noLongerShareABucket() {
        XCTAssertNotEqual(
            DirectPlayFailureKind(engineKind: EngineFailureKind.sourceRefused),
            DirectPlayFailureKind(engineKind: EngineFailureKind.sourceOpenFailed),
            "an origin answering 403 and a corrupt file are different failures"
        )
    }

    func test_originRefusal_classifiesAsNetwork() {
        XCTAssertEqual(DirectPlayFailureKind(engineKind: EngineFailureKind.sourceRefused), .network)
    }

    func test_rateLimit_classifiesAsNetwork() {
        XCTAssertEqual(DirectPlayFailureKind(engineKind: EngineFailureKind.sourceRateLimited), .network)
    }

    func test_unreadableBody_classifiesAsDemuxInit() {
        XCTAssertEqual(DirectPlayFailureKind(engineKind: EngineFailureKind.sourceOpenFailed), .demuxInit)
    }

    func test_dolbyVisionWithoutBaseLayer_classifiesAsUnsupportedCodec() {
        XCTAssertEqual(
            DirectPlayFailureKind(engineKind: EngineFailureKind.dolbyVisionRequiresHardware),
            .unsupportedCodec
        )
    }

    func test_softwarePipeline_classifiesAsDecodeInit() {
        XCTAssertEqual(
            DirectPlayFailureKind(engineKind: EngineFailureKind.softwarePipelineFailed),
            .decodeInit
        )
    }

    // MARK: - The open set

    /// AetherEngine adds kinds on minor releases. An unrecognised one must land
    /// on `.runtimeFatal`, not `.unknown`: the engine only publishes one of
    /// these when a session actually died, and `.unknown` claims we do not know
    /// that anything failed. The raw kind still reaches Sentry beside it.
    func test_unrecognisedKind_isRuntimeFatalNotUnknown() {
        let kind = DirectPlayFailureKind(engineKind: "someKindShippedAfterThisTestWasWritten")
        XCTAssertEqual(kind, .runtimeFatal)
        XCTAssertNotEqual(kind, .unknown)
    }

    func test_emptyKind_doesNotCrashAndIsRuntimeFatal() {
        XCTAssertEqual(DirectPlayFailureKind(engineKind: ""), .runtimeFatal)
    }

    // MARK: - PlayerError plumbing

    func test_engineKind_isNilForHostAuthoredErrors() {
        XCTAssertNil(PlayerError.loadFailed("whatever").engineKind)
        XCTAssertNil(PlayerError.invalidURL.engineKind)
        XCTAssertNil(PlayerError.unknown("whatever").engineKind)
    }

    func test_engineKind_survivesToTheSentryTag() {
        let error = PlayerError.engineFailure(kind: EngineFailureKind.sourceRateLimited,
                                              message: "Failed to load: HTTP 429")
        XCTAssertEqual(error.engineKind, "sourceRateLimited")
    }

    /// A hardware decode limit is the one class where retrying cannot help.
    /// Rate limiting stays retryable on purpose: upstream's note on that kind
    /// is that the same request is expected to succeed later.
    func test_retryability_followsWhatRetryingCouldActuallyChange() {
        XCTAssertFalse(
            PlayerError.engineFailure(kind: EngineFailureKind.dolbyVisionRequiresHardware,
                                      message: "no base layer").isRetryable
        )
        XCTAssertTrue(
            PlayerError.engineFailure(kind: EngineFailureKind.sourceRateLimited,
                                      message: "HTTP 429").isRetryable
        )
        XCTAssertTrue(
            PlayerError.engineFailure(kind: "somethingNew", message: "?").isRetryable
        )
    }

    /// The technical description is what reaches Sentry's message field, so the
    /// kind has to be in it even when nothing branches on that kind.
    func test_technicalDescription_carriesTheKind() {
        let description = PlayerError
            .engineFailure(kind: "audioBridgeProducedNoOutput", message: "muxer failed")
            .technicalDescription
        XCTAssertTrue(description.contains("audioBridgeProducedNoOutput"), description)
        XCTAssertTrue(description.contains("muxer failed"), description)
    }

    /// Only the kinds that change what the viewer should DO get their own
    /// sentence; the rest must still say something, not fall through to "".
    func test_userFacingDescription_isNeverEmpty() {
        for kind in [EngineFailureKind.sourceRateLimited,
                     EngineFailureKind.sourceRefused,
                     EngineFailureKind.dolbyVisionRequiresHardware,
                     EngineFailureKind.audioBridgeProducedNoOutput,
                     "someKindShippedAfterThisTestWasWritten"] {
            let copy = PlayerError.engineFailure(kind: kind, message: "x").userFacingDescription
            XCTAssertFalse(copy.isEmpty, kind)
        }
    }

    func test_userFacingDescription_distinguishesRateLimitFromGenericFailure() {
        let limited = PlayerError
            .engineFailure(kind: EngineFailureKind.sourceRateLimited, message: "x")
            .userFacingDescription
        let generic = PlayerError
            .engineFailure(kind: "somethingNew", message: "x")
            .userFacingDescription
        XCTAssertNotEqual(limited, generic)
    }

    /// A 404 the item's re-read could not fix: name the server, and offer no
    /// Try Again, which would ask for the same missing file.
    func test_fileUnavailable_namesServer_andIsNotRetryable() {
        let error = PlayerError.fileUnavailable(serverName: "Sesama")
        XCTAssertEqual(error.userFacingDescription, "This file is no longer available on Sesama.")
        XCTAssertFalse(error.isRetryable)
        XCTAssertNil(error.engineKind)
        XCTAssertEqual(PlayerError.fileUnavailable(serverName: nil).userFacingDescription,
                       "This file is no longer available on this server.")
    }
}

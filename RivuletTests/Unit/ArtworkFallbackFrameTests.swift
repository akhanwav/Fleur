// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreGraphics
import XCTest
@testable import Rivulet

final class ArtworkFallbackFrameTests: XCTestCase {

    /// A 1280x720 grey picture with black bands of the given sizes, in pixels.
    private func image(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0,
                       fill: CGFloat = 0.5) -> CGImage {
        let width = 1280, height = 720
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: fill, alpha: 1)
        // CoreGraphics' origin is the bottom-left.
        context.fill(CGRect(x: left, y: bottom, width: width - left - right, height: height - top - bottom))
        return context.makeImage()!
    }

    func test_letterboxedFrame_isAFrame() {
        XCTAssertTrue(ArtworkFallback.looksLikeVideoFrame(image(top: 90, bottom: 90)))
        XCTAssertTrue(ArtworkFallback.looksLikeVideoFrame(image(top: 22, bottom: 22)))
    }

    func test_pillarboxedFrame_isAFrame() {
        XCTAssertTrue(ArtworkFallback.looksLikeVideoFrame(image(left: 40, right: 40)))
    }

    func test_fullBleedArt_isNotAFrame() {
        XCTAssertFalse(ArtworkFallback.looksLikeVideoFrame(image()))
    }

    func test_artDarkAlongOneEdge_isNotAFrame() {
        XCTAssertFalse(ArtworkFallback.looksLikeVideoFrame(image(top: 150)))
    }

    /// Key art dark along its top and both sides (measured on a 4K background).
    func test_artDarkOnBothAxes_isNotAFrame() {
        XCTAssertFalse(ArtworkFallback.looksLikeVideoFrame(image(top: 110, left: 60, right: 50)))
    }

    func test_allBlack_isNotAFrame() {
        XCTAssertFalse(ArtworkFallback.looksLikeVideoFrame(image(fill: 0)))
    }
}

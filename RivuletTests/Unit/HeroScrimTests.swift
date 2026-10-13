// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class HeroScrimTests: XCTestCase {

    private typealias Compositor = ContinueWatchingCardCompositor
    private let region = CGRect(x: 0, y: 0.4, width: 0.4, height: 0.4)

    /// An 8 x 8 still: `left` and `right` alternate by column under the region.
    private func luma(_ left: Float, _ right: Float? = nil) -> Compositor.Grid {
        Compositor.Grid(columns: 8, rows: 8, values: (0..<64).map { $0 % 2 == 0 ? left : (right ?? left) })
    }

    private func strength(_ left: Float, _ right: Float? = nil) -> Double {
        HeroScrim.strength(under: region, luma: luma(left, right))
    }

    func testDarkCalmKeepsTodaysScrim() {
        XCTAssertEqual(strength(0.1), 1)
        XCTAssertEqual(strength(0.45), 1)
    }

    func testNoSignalKeepsTodaysScrim() {
        XCTAssertEqual(HeroScrim.strength(under: region, luma: nil), 1)
        XCTAssertEqual(HeroScrim.strength(under: .zero, luma: luma(1)), 1)
    }

    func testLumaReadsTheImage() throws {
        // White over black, 2:1.
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 64, width: 256, height: 64))
        let grid = try XCTUnwrap(HeroScrim.luma(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(grid.columns, 64)
        XCTAssertEqual(grid.rows, 32)
        XCTAssertEqual(try XCTUnwrap(grid.stats(in: CGRect(x: 0, y: 0, width: 1, height: 0.4))).mean, 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(grid.stats(in: CGRect(x: 0, y: 0.6, width: 1, height: 0.4))).mean, 0, accuracy: 0.02)
    }

    func testBoostEndsInsideItsRadii() {
        XCTAssertEqual(HeroScrim.boostAlphas.count, HeroScrim.boostLocations.count)
        XCTAssertEqual(HeroScrim.boostAlphas.last, 0)
        XCTAssertLessThanOrEqual(HeroScrim.boostLocations.last ?? 2, 1)
    }

    func testBrightBusyIsStrongerAndCapped() {
        XCTAssertGreaterThan(strength(0.7), 1)
        XCTAssertEqual(strength(1), HeroScrim.maxStrength)
        XCTAssertEqual(strength(0.6, 1), HeroScrim.maxStrength)
    }

    func testBusyNeedsMoreThanCalmAtTheSameMean() {
        XCTAssertGreaterThan(strength(0.4, 0.8), strength(0.6))
    }

    func testMonotonicInLuminance() {
        let steps = stride(from: Float(0), through: 1, by: 0.05).map { strength($0) }
        for (darker, brighter) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThanOrEqual(darker, brighter)
            XCTAssertGreaterThanOrEqual(darker, 1)
        }
    }

    func testUnitRectFollowsAspectFill() {
        // A 4:3 still in a 16:9 view overflows top and bottom by a sixth of its height.
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let unit = HeroScrim.unitRect(CGRect(x: 0, y: 0, width: 800, height: 450), in: bounds,
                                      imageSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(unit.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(unit.minY, 0.125, accuracy: 1e-9)
        XCTAssertEqual(unit.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(unit.height, 0.375, accuracy: 1e-9)
    }
}

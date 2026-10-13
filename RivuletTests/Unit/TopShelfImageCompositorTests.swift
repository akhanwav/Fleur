// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfImageCompositorTests.swift
//  RivuletTests
//
//  Tests for TopShelfImageCompositor — pure UIImage-in/UIImage-out
//  backdrop+logo compositor for Top Shelf carousel images.
//

import XCTest
import UIKit
@testable import Rivulet

final class TopShelfImageCompositorTests: XCTestCase {

    private func solid(_ color: UIColor, _ size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testOutputMatchesCanvasSize() {
        let backdrop = solid(.red, CGSize(width: 400, height: 225))
        let logo = solid(.white, CGSize(width: 200, height: 80))
        let canvas = CGSize(width: 1920, height: 1080)
        let out = TopShelfImageCompositor.compose(backdrop: backdrop, logo: logo, canvasSize: canvas)
        XCTAssertEqual(out.size.width, canvas.width, accuracy: 0.5)
        XCTAssertEqual(out.size.height, canvas.height, accuracy: 0.5)
    }

    func testOutputMatchesCanvasSizeWithNoLogo() {
        let backdrop = solid(.blue, CGSize(width: 400, height: 225))
        let canvas = CGSize(width: 1920, height: 1080)
        let out = TopShelfImageCompositor.compose(backdrop: backdrop, logo: nil, canvasSize: canvas)
        XCTAssertEqual(out.size.width, canvas.width, accuracy: 0.5)
        XCTAssertEqual(out.size.height, canvas.height, accuracy: 0.5)
    }

    func testDefaultCanvasSizeIs1920x1080() {
        let backdrop = solid(.green, CGSize(width: 400, height: 225))
        let out = TopShelfImageCompositor.compose(backdrop: backdrop, logo: nil)
        XCTAssertEqual(out.size.width, 1920, accuracy: 0.5)
        XCTAssertEqual(out.size.height, 1080, accuracy: 0.5)
    }

    // MARK: Logo placement

    private typealias Signals = ContinueWatchingCardCompositor.Signals
    private let canvas = CGSize(width: 1920, height: 1080)
    private let logoSize = CGSize(width: 600, height: 200)

    /// A 16:9 backdrop's signals: one flat brightness, and the given faces.
    private func signals(luma: Float = 0.2, faces: [CGRect]? = []) -> Signals {
        Signals(size: canvas, faces: faces,
                luma: .init(columns: 64, rows: 36, values: Array(repeating: luma, count: 64 * 36)), saliency: nil)
    }

    private func candidates() -> [CGRect] {
        TopShelfImageCompositor.logoCandidates(for: logoSize, canvas: canvas)
    }

    func testTopCentreWinsATie() {
        let place = TopShelfImageCompositor.placement(logoSize: logoSize, signals: signals(), canvas: canvas)
        XCTAssertEqual(place.rect, candidates()[0])
        XCTAssertEqual(place.rect.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertFalse(place.strongShadow)
    }

    func testFaceUnderTopCentreMovesTheLogo() {
        let face = CGRect(x: 0.45, y: 0.1, width: 0.1, height: 0.15)
        let place = TopShelfImageCompositor.placement(logoSize: logoSize, signals: signals(faces: [face]), canvas: canvas)
        XCTAssertEqual(place.rect, candidates()[1])
        let onCanvas = CGRect(x: face.minX * canvas.width, y: face.minY * canvas.height,
                              width: face.width * canvas.width, height: face.height * canvas.height)
        XCTAssertFalse(place.rect.intersects(onCanvas))
    }

    func testFaceInACroppedPosterMovesTheLogo() {
        // A 2:3 backdrop fills the width and is cropped top and bottom: top centre is about a third of the way down it.
        let face = CGRect(x: 0.45, y: 0.34, width: 0.1, height: 0.05)
        let poster = Signals(size: CGSize(width: 2000, height: 3000), faces: [face],
                             luma: .init(columns: 64, rows: 36, values: Array(repeating: 0.2, count: 64 * 36)), saliency: nil)
        let place = TopShelfImageCompositor.placement(logoSize: logoSize, signals: poster, canvas: canvas)
        XCTAssertNotEqual(place.rect, candidates()[0])
    }

    func testNoSignalKeepsTopCentre() {
        let place = TopShelfImageCompositor.placement(logoSize: logoSize, signals: .none, canvas: canvas)
        XCTAssertEqual(place.rect, candidates()[0])
        XCTAssertFalse(place.strongShadow)
        // Face detection failed: the logo stays put whatever else was read.
        let blind = TopShelfImageCompositor.placement(logoSize: logoSize, signals: signals(faces: nil), canvas: canvas)
        XCTAssertEqual(blind.rect, candidates()[0])
    }

    func testBrightBackdropTakesTheStrongShadow() {
        XCTAssertTrue(TopShelfImageCompositor.placement(logoSize: logoSize, signals: signals(luma: 0.9), canvas: canvas).strongShadow)
    }

    func testCandidatesStayOnCanvasAndClearOfTheSystemOverlay() {
        let floor = canvas.height * TopShelfImageCompositor.systemOverlayTop
        for logo in [CGSize(width: 100, height: 200), CGSize(width: 300, height: 300), logoSize,
                     CGSize(width: 1600, height: 200), CGSize(width: 2000, height: 100), .zero] {
            let rects = TopShelfImageCompositor.logoCandidates(for: logo, canvas: canvas)
            XCTAssertEqual(rects.count, TopShelfImageCompositor.moveCosts.count)
            for rect in rects {
                XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(rect), "\(logo) \(rect)")
                XCTAssertLessThanOrEqual(rect.maxY, floor, "\(logo) \(rect)")
            }
        }
    }

    // MARK: File name

    func testFileNameChangesOnlyWithItsSources() {
        let name = TopShelfImageCompositor.fileName(ratingKey: "42", backdropURL: "a", logoURL: "b")
        XCTAssertEqual(name, TopShelfImageCompositor.fileName(ratingKey: "42", backdropURL: "a", logoURL: "b"))
        XCTAssertNotEqual(name, TopShelfImageCompositor.fileName(ratingKey: "42", backdropURL: "a2", logoURL: "b"))
        XCTAssertNotEqual(name, TopShelfImageCompositor.fileName(ratingKey: "42", backdropURL: "a", logoURL: "b2"))
        // The fixed-rule files were "<ratingKey>.jpg": never a current name, so they are pruned.
        XCTAssertNotEqual(name, "42.jpg")
        XCTAssertTrue(name.hasPrefix("42-") && name.hasSuffix(".jpg"))
    }
}

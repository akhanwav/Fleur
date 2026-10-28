// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CaptionSizingTests.swift
//  RivuletTests
//
//  Pins the caption point size to what AVKit actually renders, because the app
//  reimplements Apple's caption renderer and nothing else checks the match.
//
//  Reference values were measured on the tvOS 26.5 simulator: an
//  AVPlayerViewController captioning Apple's bipbop test stream, with the same
//  cue string drawn alongside at known point sizes through the same
//  MediaAccessibility font descriptor, compared by ink width in one screenshot.
//
//  Issue #299 shipped for five builds because the constant was calibrated at a
//  single point in the multiplier's range. These cases cover both ends.
//

import XCTest
@testable import Rivulet

final class CaptionSizingTests: XCTestCase {

    private let presentationHeight: CGFloat = 1080

    /// What AVKit actually renders at each value the system can report, on
    /// tvOS's fixed 1080-point presentation. Every one of these was measured;
    /// none is derived from another. The default is the exception: AVKit draws
    /// 46.2pt there, and the app deliberately draws it about 4pt smaller.
    private let avkitSizes: [(reported: CGFloat, points: CGFloat)] = [
        (0.35, 18.5), (0.60, 31.0), (1.00, CaptionSizingTests.defaultSize), (1.50, 78.0), (2.00, 104.1)
    ]

    /// The default rung: AVKit's 46.2pt less two deliberate ~2pt reductions.
    private static let defaultSize: CGFloat = 42.1

    /// The regression issue #299 reported: 57.1pt where AVKit draws 46pt.
    func test_pointSize_atSystemDefault_isTheChosenDefault() {
        let size = CaptionOverlayView.Metrics.pointSize(
            presentationHeight: presentationHeight, fontScale: 1.0)
        XCTAssertEqual(size, Self.defaultSize, accuracy: 0.6,
                       "Caption size at the default setting moved. Got \(size)pt.")
    }

    /// AVKit's size is NOT a linear function of the reported value — it runs
    /// about 11% above a plain multiply at every setting except the default.
    /// Asserting every rung is the point: #299 shipped because only one was
    /// ever checked.
    func test_pointSize_matchesAVKitAtEveryReportableSize() {
        for expected in avkitSizes {
            let size = CaptionOverlayView.Metrics.pointSize(
                presentationHeight: presentationHeight, fontScale: expected.reported)
            XCTAssertEqual(size, expected.points, accuracy: 0.6,
                           "At reported \(expected.reported) AVKit draws "
                           + "\(expected.points)pt, got \(size)pt.")
        }
    }

    /// Guards the specific mistake that caused #299: treating the reported value
    /// as a multiplier against the default size.
    func test_pointSize_isNotAPlainMultipleOfTheDefault() {
        let base = CaptionOverlayView.Metrics.pointSize(
            presentationHeight: presentationHeight, fontScale: 1.0)
        for reported in [0.35, 0.6, 1.5, 2.0] as [CGFloat] {
            let size = CaptionOverlayView.Metrics.pointSize(
                presentationHeight: presentationHeight, fontScale: reported)
            XCTAssertGreaterThan(size / base, reported * 1.05,
                                 "Reported \(reported) must not scale linearly; "
                                 + "AVKit runs ~11% higher.")
        }
    }

    /// Values off the ladder must stay bounded by the measured ends rather than
    /// extrapolating into nonsense.
    func test_pointSize_clampsBeyondTheMeasuredEnds() {
        let low = CaptionOverlayView.Metrics.pointSize(presentationHeight: presentationHeight,
                                                       fontScale: 0.01)
        let high = CaptionOverlayView.Metrics.pointSize(presentationHeight: presentationHeight,
                                                        fontScale: 99)
        XCTAssertEqual(low, 18.5, accuracy: 0.6)
        XCTAssertEqual(high, 104.1, accuracy: 0.6)
    }

    /// A degenerate layout pass must not collapse captions to nothing.
    func test_pointSize_withZeroHeight_fallsBackToTheAssumedPresentation() {
        let size = CaptionOverlayView.Metrics.pointSize(presentationHeight: 0, fontScale: 1.0)
        XCTAssertEqual(size, Self.defaultSize, accuracy: 0.6)
    }

    /// An unset or out-of-range system value reads as "no scaling". The API
    /// reports 1.0 for anything off its five-bucket ladder.
    func test_fontScale_treatsNonPositiveAsUnscaled() {
        XCTAssertEqual(CaptionAppearance.fontScale(forRelativeSize: 0), 1.0)
        XCTAssertEqual(CaptionAppearance.fontScale(forRelativeSize: -1), 1.0)
    }

    /// Every value the API can actually return must pass through untouched; the
    /// clamp is a sanity net and must never bind on a real setting.
    func test_fontScale_passesThroughEveryReportableValue() {
        for reported in [0.35, 0.6, 1.0, 1.5, 2.0] as [CGFloat] {
            XCTAssertEqual(CaptionAppearance.fontScale(forRelativeSize: reported), reported,
                           "The clamp must not alter \(reported), which tvOS really reports.")
        }
    }
}

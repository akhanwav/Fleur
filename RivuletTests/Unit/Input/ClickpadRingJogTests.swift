// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class ClickpadRingJogTests: XCTestCase {

    /// Feeds an arc on the clickpad (dpad units, y up). Angles are compass
    /// degrees: 0 = top, 90 = right, so increasing degrees run clockwise.
    private func drive(_ jog: inout ClickpadRingJog, radius: Float, from: Double, to: Double, steps: Int = 120) -> Double {
        var total = 0.0
        for i in 0...steps {
            let degrees = from + (to - from) * Double(i) / Double(steps)
            let rad = degrees * .pi / 180
            total += jog.feed(x: radius * Float(sin(rad)), y: radius * Float(cos(rad))) ?? 0
        }
        return total
    }

    func test_wheelPosition_runsClockwiseFromTwelve() {
        // Matches _UIRotaryGestureRecognizer's _calculateWheelPositionForTouchLocation:.
        XCTAssertEqual(ClickpadRingJog.wheelPosition(dx: 0, dy: -0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(ClickpadRingJog.wheelPosition(dx: 0.5, dy: 0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(ClickpadRingJog.wheelPosition(dx: 0, dy: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ClickpadRingJog.wheelPosition(dx: -0.5, dy: 0), 0.75, accuracy: 1e-9)
    }

    func test_clockwiseTurn_isPositive_andWeightedByRadius() {
        var jog = ClickpadRingJog()
        // Radius 0.8 dpad = 0.4 digitizer: full weight. The 37.5° spent classifying
        // is dropped, and the five-sample mean trails the finger by two samples.
        let turn = drive(&jog, radius: 0.8, from: 0, to: 360, steps: 360)
        XCTAssertTrue(jog.isJogging)
        XCTAssertEqual(turn, (360 - 38 - 2) / 360, accuracy: 0.01)
    }

    func test_jogStart_doesNotJump() {
        var jog = ClickpadRingJog()
        var first: Double?
        for i in 0...120 {
            let rad = Double(i) * .pi / 180
            if let turn = jog.feed(x: Float(0.8 * sin(rad)), y: Float(0.8 * cos(rad))), first == nil { first = turn }
        }
        XCTAssertEqual(first, 0, "the turn spent classifying is not scrubbed")
    }

    func test_angleThreshold_scalesWithRadius() {
        var jog = ClickpadRingJog()
        // 15 / 0.4 = 37.5° at full radius: 30° is not yet a jog.
        _ = drive(&jog, radius: 0.8, from: 0, to: 30)
        XCTAssertEqual(jog.classification, .undecided)
        _ = drive(&jog, radius: 0.8, from: 30, to: 40)
        XCTAssertTrue(jog.isJogging)
    }

    func test_touchStartingNearCentre_neverJogs() {
        var jog = ClickpadRingJog()
        // Radius 0.4 dpad = 0.2 digitizer, under the 0.23 start radius.
        _ = drive(&jog, radius: 0.4, from: 90, to: 270)
        XCTAssertEqual(jog.classification, .swipe)
    }

    func test_seconds_followAVKitsVelocityGain() {
        // One weighted turn on a two-hour title: 100pt x gain over AVKit's 1760pt bar.
        XCTAssertEqual(ClickpadRingJog.seconds(forTurn: 1, velocity: 0.5, duration: 7200), 100 * 1.25 / 1760 * 7200, accuracy: 1e-6)
        XCTAssertEqual(ClickpadRingJog.seconds(forTurn: -1, velocity: -4, duration: 7200), -100 * 2.5 / 1760 * 7200, accuracy: 1e-6)
        // The two gain pieces meet at one revolution a second.
        XCTAssertEqual(ClickpadRingJog.seconds(forTurn: 1, velocity: 0.999_999, duration: 1760),
                       ClickpadRingJog.seconds(forTurn: 1, velocity: 1, duration: 1760), accuracy: 1e-3)
    }

    func test_velocity_isWeightedRevolutionsPerSecond() {
        var jog = ClickpadRingJog()
        // A quarter turn at full weight over a quarter second: one revolution a second.
        for i in 0...25 {
            let rad = Double(i) / 25 * .pi / 2
            _ = jog.feed(x: Float(0.8 * sin(rad)), y: Float(0.8 * cos(rad)), time: Double(i) * 0.01)
        }
        XCTAssertTrue(jog.isJogging)
        XCTAssertEqual(jog.velocity, 1, accuracy: 0.02)
    }

    func test_fingerPosition_followsTheFingerNotTheTurnWeight() {
        var jog = ClickpadRingJog()
        XCTAssertNil(jog.fingerPosition)
        // A small circle weighs less per revolution, but the finger still sits at 3 o'clock.
        _ = drive(&jog, radius: 0.5, from: 0, to: 90)
        XCTAssertEqual(jog.fingerPosition ?? -1, 0.25, accuracy: 0.01)
        _ = jog.feed(x: 0, y: 0)
        XCTAssertNil(jog.fingerPosition, "a lift ends the jog")
    }

    func test_counterclockwiseTurn_isNegative() {
        var jog = ClickpadRingJog()
        let turn = drive(&jog, radius: 0.8, from: 180, to: 0)
        XCTAssertLessThan(turn, -0.35)
    }

    func test_smallerCircle_turnsLess() {
        var outer = ClickpadRingJog(), inner = ClickpadRingJog()
        let outerTurn = drive(&outer, radius: 0.8, from: 90, to: 450, steps: 360)
        let innerTurn = drive(&inner, radius: 0.5, from: 90, to: 450, steps: 360)
        XCTAssertLessThan(innerTurn, outerTurn * 0.7)
    }

    func test_crossingTwelve_doesNotJump() {
        var jog = ClickpadRingJog()
        let turn = drive(&jog, radius: 0.8, from: -90, to: 90, steps: 180)
        XCTAssertEqual(turn, (180 - 38 - 2) / 360, accuracy: 0.01)
    }

    func test_straightSwipeThroughCentre_isASwipe() {
        var jog = ClickpadRingJog()
        var total = 0.0
        for i in 0...60 {
            total += jog.feed(x: -0.9 + 1.8 * Float(i) / 60, y: 0.05) ?? 0
        }
        XCTAssertEqual(jog.classification, .swipe)
        XCTAssertEqual(total, 0)
    }

    func test_turnBelowThreshold_staysUndecided() {
        var jog = ClickpadRingJog()
        let turn = drive(&jog, radius: 0.8, from: 0, to: 10)
        XCTAssertEqual(jog.classification, .undecided)
        XCTAssertEqual(turn, 0)
    }

    func test_lift_resetsClassification() {
        var jog = ClickpadRingJog()
        _ = drive(&jog, radius: 0.8, from: 0, to: 90)
        XCTAssertTrue(jog.isJogging)
        XCTAssertNil(jog.feed(x: 0, y: 0))
        XCTAssertEqual(jog.classification, .undecided)
    }

    func test_centreDeadzone_holdsTheJogWithoutMoving() {
        var jog = ClickpadRingJog()
        _ = drive(&jog, radius: 0.8, from: 0, to: 90)
        XCTAssertTrue(jog.isJogging)
        // Radius 0.3 dpad = 0.15 digitizer, inside the 0.2 deadzone.
        XCTAssertEqual(jog.feed(x: 0.3, y: 0), 0)
        XCTAssertTrue(jog.isJogging)
    }
}

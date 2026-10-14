import XCTest
@testable import Rivulet

final class FocusScrollMotionTests: XCTestCase {
    private let frame60 = 1.0 / 60

    func test_follow_startsWithoutAJump_andSettles() {
        var y: CGFloat = 0, v: CGFloat = 0, frames = 0
        var first: CGFloat?
        while frames < 600 {
            let s = FocusScrollMotion.follow(from: y, to: 500, velocity: v, dt: frame60, viewport: 1080)
            first = first ?? s.y
            y = s.y; v = s.velocity; frames += 1
            if s.done { break }
        }
        XCTAssertLessThanOrEqual(first!, 10.5, "first frame is capped by the acceleration limit")
        XCTAssertEqual(y, 500)
        XCTAssertLessThan(frames, 90, "settles within ~1.5 s")
    }

    func test_follow_retargetKeepsSpeed() {
        var y: CGFloat = 0, v: CGFloat = 0
        for _ in 0..<20 {
            let s = FocusScrollMotion.follow(from: y, to: 500, velocity: v, dt: frame60, viewport: 1080)
            y = s.y; v = s.velocity
        }
        let before = v
        let s = FocusScrollMotion.follow(from: y, to: 1000, velocity: v, dt: frame60, viewport: 1080)
        XCTAssertGreaterThanOrEqual(s.velocity, before, "a further target never slows the scroll")
    }

    func test_follow_farTargetIsBroughtToTwoViewports() {
        let s = FocusScrollMotion.follow(from: 0, to: 10_000, velocity: 0, dt: frame60, viewport: 1000)
        XCTAssertGreaterThanOrEqual(s.y, 8000)
    }

    func test_minimalOffset_keepsEdgeInsetAndOnlyMovesWhenNeeded() {
        let row = CGRect(x: 0, y: 1500, width: 260, height: 430)
        XCTAssertEqual(FocusScrollMotion.minimalOffset(revealing: row, from: 0, height: 1080), 1500 + 430 - 1080 + 180)
        XCTAssertEqual(FocusScrollMotion.minimalOffset(revealing: row, from: 1100, height: 1080), 1100)
        XCTAssertEqual(FocusScrollMotion.minimalOffset(revealing: row, from: 2000, height: 1080), 1500 - 180)
    }
}

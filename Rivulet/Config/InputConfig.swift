// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InputConfig.swift
//  Rivulet
//
//  Shared constants for remote/controller/keyboard input behavior.
//

import Foundation

enum InputConfig {
    static let holdThreshold: TimeInterval = 0.4
    static let seekCoalesceInterval: TimeInterval = 0.05
    static let actionDedupeWindow: TimeInterval = 0.08
    static let transportDedupeWindow: TimeInterval = 0.35
    /// A single directional press-and-hold can be observed by TWO independent
    /// detectors at the same ~0.4s threshold — a GameController hold timer
    /// (.siriMicroGamepad, via an async hop) and a UIKit press path (.irPress).
    /// Both emit `.scrubNudge`, and the async skew routinely pushes them >0.08s
    /// apart, so each was bumping the shuttle a level (a single hold jumping
    /// 2x→4x on its own). This wider CROSS-SOURCE window coalesces the two into
    /// one hold entry, while deliberate same-source re-clicks (which bump on
    /// purpose) are never deduped because they share a source. Sized above the
    /// observed skew but below a human's fastest deliberate double-click.
    ///
    /// No player has two press detectors any more (`RemoteInputHandler` acts
    /// only on input with no UIPress), but an MPRemoteCommand seek can still
    /// pair with a press.
    static let scrubNudgeDedupeWindow: TimeInterval = 0.25
    static let blockDismissTimeout: TimeInterval = 0.3

    /// Single-press Left/Right skip. Applied uniformly across every remote and
    /// focus state (content-focused, IR d-pad, keyboard, and the focused
    /// scrubber). User-configurable via Settings → Playback → Skip Length.
    static var tapSeekSeconds: TimeInterval {
        TimeInterval(SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue))
    }
    /// Single-press Left skip. Follows Skip Forward until Settings → Playback →
    /// Skip Back Length is set (#335).
    static var tapSeekBackSeconds: TimeInterval {
        TimeInterval(SettingsStore.int(SkipInterval.backStorageKey, default: Int(tapSeekSeconds)))
    }
    /// Signed single-press skip for a direction.
    static func tapSeekDelta(forward: Bool) -> TimeInterval {
        forward ? tapSeekSeconds : -tapSeekBackSeconds
    }
    static let jumpSeekSeconds: TimeInterval = 30

    static let dpadThreshold: Float = 0.3
    /// How far out a touch must rest for a clickpad `.select` to count as a
    /// Left/Right EDGE click (1st-generation Siri Remote, whose clicks all
    /// arrive as `.select`). Stricter than `dpadThreshold` because a wrong yes
    /// skips the video instead of showing the controls.
    static let edgeClickThreshold: Float = 0.6
    static let joystickDeadzone: Float = 0.2

    /// Left/right region of a Siri Remote clickpad touch in absolute dpad
    /// coordinates: true = right, false = left, nil = anything else.
    ///
    /// Horizontal must DOMINATE, not just clear the threshold. An x-only test
    /// read every Up or Down click made slightly off the vertical axis (say
    /// x 0.35, y 0.9) as a Right click, so one press both raised the rail and
    /// queued a skip.
    static func clickpadHorizontalDirection(x: Float, y: Float, threshold: Float = dpadThreshold) -> Bool? {
        guard abs(x) > threshold, abs(x) > abs(y) else { return nil }
        return x > 0
    }

    /// Jog turn batched before one scrub step (about 1.8°).
    static let wheelEmitRevolutions = 0.005

    // MARK: - Swipe-to-Scrub (touchpad pan while the progress bar is up or paused)

    /// Seconds of seek per point of pan translation at or below
    /// `scrubVelocitySlow` — the fine-adjustment rate for a slow, deliberate
    /// swipe. Calibrated against a ~1920pt-wide clickpad swipe (tvOS's point
    /// width) so a full-width slow swipe moves about a minute regardless of
    /// the title's runtime (1920 * 0.03 ≈ 58s).
    static let scrubSecondsPerPointSlow: Double = 0.03
    /// Seconds of seek per point of pan translation at or above
    /// `scrubVelocityFast` — the rate a fast, deliberate flick settles into,
    /// letting it cover much larger distances than a slow drag.
    static let scrubSecondsPerPointFast: Double = 0.3
    /// Pan velocity (points/sec) at or below which scrubbing uses
    /// `scrubSecondsPerPointSlow`. Raised well above typical slow-drag
    /// velocity so an ordinary deliberate swipe stays in the fine-adjustment
    /// rate for its whole length.
    static let scrubVelocitySlow: Double = 600
    /// Pan velocity (points/sec) at or above which scrubbing uses
    /// `scrubSecondsPerPointFast`. Between the two thresholds the rate eases
    /// in (see `scrubSecondsPerPoint`) rather than switching abruptly, so
    /// speeding up or slowing down mid-swipe accelerates gently. Set high
    /// enough that only a really deliberate flick reaches it.
    static let scrubVelocityFast: Double = 4000

    /// Seconds-per-point of pan translation for a swipe currently moving at
    /// `velocity` points/sec (sign ignored). Eases from
    /// `scrubSecondsPerPointSlow` to `scrubSecondsPerPointFast` with a
    /// smoothstep between `scrubVelocitySlow` and `scrubVelocityFast`, so a
    /// small, slow movement stays fine-grained (a few seconds) while only a
    /// fast flick reaches the coarse rate — no separate post-release bonus
    /// is needed, so lifting the finger never adds extra motion.
    static func scrubSecondsPerPoint(forVelocity velocity: Double) -> Double {
        let magnitude = abs(velocity)
        let span = scrubVelocityFast - scrubVelocitySlow
        guard span > 0 else { return scrubSecondsPerPointSlow }
        let t = min(max((magnitude - scrubVelocitySlow) / span, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return scrubSecondsPerPointSlow + eased * (scrubSecondsPerPointFast - scrubSecondsPerPointSlow)
    }

    /// Low-pass factor for smoothing `UIPanGestureRecognizer.velocity(in:)`
    /// before it picks a scrub rate: `smoothed += (raw - smoothed) * factor`.
    /// Per-callback touch velocity is noisy frame to frame (see
    /// `ClickpadRingJog`'s own sample averaging for the ring-jog's version of
    /// the same problem); fed straight into `scrubSecondsPerPoint` that noise
    /// made the swipe's effective speed visibly jump even during one steady
    /// drag. Lower = more smoothing (slower to react to a real speed change).
    static let scrubVelocitySmoothingFactor: Double = 0.25
}

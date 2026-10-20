// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AudioSyncAdjustments.swift
//  Rivulet
//
//  User-tunable audio/video sync offset: one global value, applied to every
//  title. Adjustable from Settings → Playback and live from the player's
//  Audio panel — both read and write the same stored value, so a change
//  either place shows up in the other. 10ms per stepper press.
//
//  aether route only: this maps to AetherEngine's own audio-delay feature
//  (AE#464), and AVPlayer/the `hls` route has nothing to set it with — see
//  the doc comment on AetherEngine's own `setAudioDelay(_:)`. Callers gate on
//  `aetherPlayer != nil` before offering this control at all.
//

import Foundation

enum AudioSyncAdjustments {

    /// One stepper press, in milliseconds.
    static let stepMs = 10

    /// UI-side clamp. Narrower than AetherEngine's own ±2000ms ceiling
    /// (AudioDelayPolicy.maxAbsSeconds) — plenty for any real AVR/soundbar
    /// fixed delay.
    static let maxAbsMs = 1000

    private static let globalDefaultKey = "audioSyncGlobalDefaultMs"

    /// The offset applied to every title. 0 until set.
    static var globalDefaultMs: Int {
        clamp(UserDefaults.standard.integer(forKey: globalDefaultKey))
    }

    /// Persists the offset. A value of 0 removes the key so a fresh install
    /// costs nothing.
    static func setGlobalDefaultMs(_ ms: Int) {
        let clamped = clamp(ms)
        if clamped == 0 {
            UserDefaults.standard.removeObject(forKey: globalDefaultKey)
        } else {
            UserDefaults.standard.set(clamped, forKey: globalDefaultKey)
        }
    }

    /// "0 ms", "+40 ms", "-120 ms" — the stepper's centre label.
    static func formatted(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    private static func clamp(_ ms: Int) -> Int {
        max(-maxAbsMs, min(maxAbsMs, ms))
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AudioSyncAdjustments.swift
//  Rivulet
//
//  User-tunable audio/video sync offset, surfaced as a stepper in Settings
//  (a global default, e.g. a soundbar's fixed processing delay) and another
//  in the player's Audio panel (a per-title delta on top of it, sticky like
//  SubtitleAdjustments' delay/height). 10ms per stepper press.
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

    /// UI-side clamp for both the global default and a per-title delta.
    /// Narrower than AetherEngine's own ±2000ms ceiling (AudioDelayPolicy.
    /// maxAbsSeconds) — plenty for any real AVR/soundbar fixed delay or
    /// per-title correction, with headroom left under the engine's own clamp
    /// even with both layers at their extremes.
    static let maxAbsMs = 1000

    private static let globalDefaultKey = "audioSyncGlobalDefaultMs"

    /// The fixed offset applied to every title (e.g. a soundbar's known
    /// processing delay), set in Settings → Playback. 0 until set.
    static var globalDefaultMs: Int {
        clamp(UserDefaults.standard.integer(forKey: globalDefaultKey))
    }

    /// Persists the global default. A value of 0 removes the key so a fresh
    /// install costs nothing.
    static func setGlobalDefaultMs(_ ms: Int) {
        let clamped = clamp(ms)
        if clamped == 0 {
            UserDefaults.standard.removeObject(forKey: globalDefaultKey)
        } else {
            UserDefaults.standard.set(clamped, forKey: globalDefaultKey)
        }
    }

    /// Defaults key holding one title's delta. A key per media, like
    /// `SubtitleAdjustments.heightKey`, so a title never adjusted costs
    /// nothing and clearing one is a plain remove.
    private static func perTitleKey(forMediaKey mediaKey: String) -> String {
        "audioSyncOffsetMs:\(mediaKey)"
    }

    /// This title's delta ON TOP OF the global default. 0 when never
    /// adjusted.
    static func perTitleMs(forMediaKey mediaKey: String) -> Int {
        clamp(UserDefaults.standard.integer(forKey: perTitleKey(forMediaKey: mediaKey)))
    }

    /// Persists `ms` for `mediaKey`. A value of 0 removes the entry, so a
    /// title the user only ever nudged relative to a changing global default
    /// keeps tracking it instead of freezing at today's sum.
    static func setPerTitleMs(_ ms: Int, forMediaKey mediaKey: String) {
        let key = perTitleKey(forMediaKey: mediaKey)
        let clamped = clamp(ms)
        if clamped == 0 {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(clamped, forKey: key)
        }
    }

    /// What's actually applied to the engine: the global default plus this
    /// title's delta.
    static func effectiveMs(forMediaKey mediaKey: String) -> Int {
        globalDefaultMs + perTitleMs(forMediaKey: mediaKey)
    }

    /// "0 ms", "+40 ms", "-120 ms" — the stepper's centre label.
    static func formatted(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    private static func clamp(_ ms: Int) -> Int {
        max(-maxAbsMs, min(maxAbsMs, ms))
    }
}

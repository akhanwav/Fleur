// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AudioSyncAdjustments.swift
//  Rivulet
//
//  User-tunable audio/video sync offset, surfaced as a stepper in Settings
//  (a global default, e.g. a soundbar's fixed processing delay) and another
//  in the player's Audio panel (this title's own ABSOLUTE offset, sticky
//  like SubtitleAdjustments' delay/height — not a delta on top of the
//  global default). 10ms per stepper press.
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

    /// UI-side clamp for both the global default and a title's own offset.
    /// Narrower than AetherEngine's own ±2000ms ceiling (AudioDelayPolicy.
    /// maxAbsSeconds) — plenty for any real AVR/soundbar fixed delay or
    /// per-title correction.
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

    /// Defaults key holding one title's own offset. A key per media, like
    /// `SubtitleAdjustments.heightKey`, so a title never adjusted costs
    /// nothing and clearing one is a plain remove.
    private static func titleKey(forMediaKey mediaKey: String) -> String {
        "audioSyncOffsetMs:\(mediaKey)"
    }

    /// This title's own stored ABSOLUTE offset, or nil when it has never
    /// been adjusted — in which case it tracks the global default live,
    /// including any later change to it. `.object(forKey:)` rather than
    /// `.integer(forKey:)` on purpose: an explicit "0 ms" must read back
    /// as set, not be indistinguishable from "never touched".
    static func storedMs(forMediaKey mediaKey: String) -> Int? {
        UserDefaults.standard.object(forKey: titleKey(forMediaKey: mediaKey)) as? Int
    }

    /// Persists `ms` as this title's own absolute offset, independent of the
    /// global default from now on.
    static func setStoredMs(_ ms: Int, forMediaKey mediaKey: String) {
        UserDefaults.standard.set(clamp(ms), forKey: titleKey(forMediaKey: mediaKey))
    }

    /// Clears this title's override; it goes back to tracking the global
    /// default live.
    static func resetToDefault(forMediaKey mediaKey: String) {
        UserDefaults.standard.removeObject(forKey: titleKey(forMediaKey: mediaKey))
    }

    /// What's actually applied to the engine: this title's own stored offset,
    /// or the global default when it has never been adjusted.
    static func effectiveMs(forMediaKey mediaKey: String) -> Int {
        storedMs(forMediaKey: mediaKey) ?? globalDefaultMs
    }

    /// "0 ms", "+40 ms", "-120 ms" — the stepper's centre label.
    static func formatted(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    private static func clamp(_ ms: Int) -> Int {
        max(-maxAbsMs, min(maxAbsMs, ms))
    }
}

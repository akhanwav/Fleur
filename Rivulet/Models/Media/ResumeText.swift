// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ResumeText.swift
//  Rivulet
//
//  The time left after the server's resume point ("42 min left"), for the
//  Play button's title (`EpisodePicker.playTitle`) wherever it shows. Whether
//  there is a resume point at all is `WatchProgressPolicy`'s call, as
//  everywhere else.
//

import Foundation

enum ResumeText {
    /// "42 min left", "1 hr 12 min left", "2 hr left"; nil without a resume
    /// point or a runtime to measure it against. Rounded up, so the last
    /// minute still reads "1 min left".
    static func timeLeft(offsetSeconds: TimeInterval, runtimeSeconds: TimeInterval?) -> String? {
        guard let runtime = runtimeSeconds, runtime > 0,
              WatchProgressPolicy.hasResumePoint(offsetSeconds: offsetSeconds, runtimeSeconds: runtime)
        else { return nil }
        let minutes = max(1, Int((max(0, runtime - offsetSeconds) / 60).rounded(.up)))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) min left" }
        return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
    }
}

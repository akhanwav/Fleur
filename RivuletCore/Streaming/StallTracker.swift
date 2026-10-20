// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum StallVerdict: Equatable, Sendable {
    case ignored
    case counted
    case stepDown
}

/// Auto's step-down rule: two stalls within a minute. Seeks and loads buffer by design.
nonisolated struct StallTracker: Sendable {
    static let window: TimeInterval = 60
    static let longStall: TimeInterval = 10
    static let grace: TimeInterval = 5

    private var stalls: [Date] = []
    private var quietUntil: Date = .distantPast

    mutating func noteSeekOrLoad(at date: Date) {
        quietUntil = date.addingTimeInterval(Self.grace)
    }

    /// Like `noteSeekOrLoad`, but for a pause expected to run longer than a
    /// quick seek — an audio-sync reload on AetherEngine's loopback route is
    /// a full source reopen, comparable in cost to the initial load itself,
    /// not a quick in-place correction. The caller picks a duration that
    /// covers it without silencing real stalls for long after.
    mutating func noteExpectedPause(at date: Date, quietFor duration: TimeInterval) {
        quietUntil = date.addingTimeInterval(duration)
    }

    /// A step-down spends the stalls behind it; the new step starts with a clean count.
    mutating func noteStepDown() {
        stalls.removeAll()
    }

    mutating func bufferingStarted(at date: Date) -> StallVerdict {
        guard date >= quietUntil else { return .ignored }
        stalls = stalls.filter { date.timeIntervalSince($0) < Self.window } + [date]
        guard stalls.count >= 2 else { return .counted }
        stalls.removeAll()
        return .stepDown
    }

    /// A counted stall still going after this long steps down on its own.
    func isLongStall(startedAt start: Date, now: Date) -> Bool {
        now.timeIntervalSince(start) >= Self.longStall
    }
}

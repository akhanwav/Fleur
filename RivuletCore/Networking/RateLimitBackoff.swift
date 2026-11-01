// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RateLimitBackoff.swift
//  Rivulet
//
//  What a 429 means for the next request to that host. `PlexNetworkManager`
//  sends every Plex request through this: after a 429 the host is left alone
//  for its `Retry-After` (else 2, 4, 8... seconds, up to a minute), a short
//  wait is sat out and a GET sent once more, and a long one fails at once
//  rather than holding a page open.
//

import Foundation
import os

nonisolated final class RateLimitBackoff: Sendable {
    static let shared = RateLimitBackoff()

    /// The longest a request waits for a host instead of failing.
    static let maxWait: TimeInterval = 10
    static let maxDelay: TimeInterval = 120

    private struct State {
        var blockedUntil: [String: Date] = [:]
        var strikes: [String: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How long to leave the host alone: its `Retry-After` in seconds when it
    /// sent one, else doubling with each 429 in a row.
    static func delay(retryAfter: String?, strikes: Int) -> TimeInterval {
        if let seconds = retryAfter.flatMap(TimeInterval.init), seconds >= 0 { return min(seconds, maxDelay) }
        return min(pow(2, Double(max(strikes, 1))), 60)
    }

    /// The seconds still to wait for `host`; zero when it is clear.
    func remainingWait(host: String?, now: Date = Date()) -> TimeInterval {
        guard let host else { return 0 }
        return state.withLock { max(0, ($0.blockedUntil[host] ?? now).timeIntervalSince(now)) }
    }

    /// Records a 429 and returns how long the host is now left alone.
    @discardableResult
    func noteRateLimited(host: String?, retryAfter: String?, now: Date = Date()) -> TimeInterval {
        guard let host else { return 0 }
        return state.withLock { state in
            let strikes = (state.strikes[host] ?? 0) + 1
            state.strikes[host] = strikes
            let delay = Self.delay(retryAfter: retryAfter, strikes: strikes)
            state.blockedUntil[host] = now.addingTimeInterval(delay)
            return delay
        }
    }

    func noteAnswered(host: String?) {
        guard let host else { return }
        state.withLock { state in
            state.strikes[host] = nil
            state.blockedUntil[host] = nil
        }
    }
}

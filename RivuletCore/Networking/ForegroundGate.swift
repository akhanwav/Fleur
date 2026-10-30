// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ForegroundGate.swift
//  Rivulet
//
//  Requests that must not be on the wire while the app is in the background.
//
//  A backgrounded app is frozen within seconds, with whatever it had in
//  flight: a request frozen mid-transfer wakes, maybe hours later, into a
//  connection that went away while the device slept. Work that only serves
//  the screen (TMDB, the library index, other servers' lookups, Home's polls)
//  goes through here. `enterBackground` cancels its requests; each one waits
//  for `enterForeground` and is sent again, so a caller sees a slow request,
//  never a failed one. A request made while backgrounded waits before it is
//  sent.
//
//  The host drives it from its lifecycle notifications. A host that never
//  calls it gets plain `URLSession` requests.
//

import Foundation
import os

nonisolated final class ForegroundGate: Sendable {
    static let shared = ForegroundGate()

    /// Set around work that should wait out the background. Child tasks and
    /// `Task {}` inherit it; `Task.detached` does not.
    @TaskLocal static var holdsInBackground = false

    /// `Task.detached`, which inherits no task-locals, with its requests held.
    @discardableResult
    static func detached(priority: TaskPriority? = nil,
                         operation: @Sendable @escaping () async -> Void) -> Task<Void, Never> {
        Task.detached(priority: priority) {
            await $holdsInBackground.withValue(true) { await operation() }
        }
    }

    private struct State {
        var inBackground = false
        /// Bumped by each `enterBackground`, so a request can tell the gate
        /// cancelled it from any other failure.
        var epoch = 0
        var inFlight: [UUID: Task<(Data, URLResponse), any Error>] = [:]
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func enterBackground() {
        let inFlight = state.withLock { state -> [Task<(Data, URLResponse), any Error>] in
            guard !state.inBackground else { return [] }
            state.inBackground = true
            state.epoch += 1
            return Array(state.inFlight.values)
        }
        inFlight.forEach { $0.cancel() }
    }

    func enterForeground() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.inBackground = false
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    /// `session.data(for:)`, held over the background when the calling work
    /// asked for it (`holdsInBackground`) or `always` is set.
    func data(for request: URLRequest, in session: URLSession,
              always: Bool = false) async throws -> (Data, URLResponse) {
        guard always || Self.holdsInBackground else { return try await session.data(for: request) }
        while true {
            try await waitForForeground()
            let id = UUID()
            let task = Task { try await session.data(for: request) }
            let epoch = state.withLock { state -> Int? in
                guard !state.inBackground else { return nil }
                state.inFlight[id] = task
                return state.epoch
            }
            guard let epoch else {
                task.cancel()
                continue
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                state.withLock { _ = $0.inFlight.removeValue(forKey: id) }
                return result
            } catch {
                let cancelledByGate = state.withLock { state -> Bool in
                    state.inFlight.removeValue(forKey: id)
                    return state.epoch != epoch
                }
                // The caller's own cancellation, or a real failure, is theirs.
                guard cancelledByGate, !Task.isCancelled else { throw error }
            }
        }
    }

    private func waitForForeground() async throws {
        try Task.checkCancellation()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiting = state.withLock { state -> Bool in
                    guard state.inBackground else { return false }
                    state.waiters[id] = continuation
                    return true
                }
                if !waiting { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
        try Task.checkCancellation()
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MainServerHealth.swift
//  Rivulet
//
//  Whether the main Plex server answers, known within seconds, so the app can
//  keep working from the other servers while it is down without ever changing
//  which server is main.
//
//  Every request goes through `ForegroundGate.data`, which reports to this:
//  a request to the main server that fails to connect (timeout, refused,
//  lost) starts a probe of its `/identity` with a short timeout; a request
//  that gets any answer means it is up. While it is down, requests to it fail
//  at once instead of waiting out the 30s request timeout, and it is probed
//  every `retryInterval` until it answers. Each change is posted on the main
//  thread as `didChange`.
//
//  Debug builds take `PLOX_SIMULATE_MAIN_OFFLINE=<seconds>` at launch: every
//  request to the main server fails to connect for that long, then the server
//  "comes back", which is how this was tested.
//

import Foundation
import os

private let healthLog = Logger(subsystem: "com.rivulet.app", category: "MainServerHealth")

nonisolated final class MainServerHealth: Sendable {
    static let shared = MainServerHealth()

    /// Posted on the main thread when the main server goes offline or comes back.
    static let didChange = Notification.Name("MainServerHealthDidChange")

    /// Marks a request as the health probe, which is never failed fast.
    static let probeHeader = "X-Plox-Health-Probe"

    static let probeTimeout: TimeInterval = 4
    static let retryInterval: TimeInterval = 10

    private struct State {
        var baseURL: String?
        var host: String?
        var token: String?
        var isOffline = false
        var isProbing = false
        var retryTask: Task<Void, Never>?
        var simulatedUntil: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["PLOX_SIMULATE_MAIN_OFFLINE"].flatMap(TimeInterval.init) {
            state.withLock { $0.simulatedUntil = Date().addingTimeInterval(seconds) }
            healthLog.info("[Health] simulating the main server offline for \(Int(seconds), privacy: .public)s")
        }
        #endif
    }

    /// True while the main server is known not to answer.
    var isOffline: Bool { state.withLock { $0.isOffline } }

    /// Whether a URL is the main server's.
    func isMainServer(_ url: URL?) -> Bool {
        guard let host = url?.host else { return false }
        return state.withLock { $0.host == host }
    }

    /// The signed-in server's address and token; a new address is probed at once.
    func setMainServer(url: String?, token: String?) {
        let host = url.flatMap { URL(string: $0)?.host }
        let changed = state.withLock { state -> Bool in
            let changed = state.host != host
            state.baseURL = url
            state.host = host
            if token != nil { state.token = token }
            if changed {
                state.isOffline = false
                state.retryTask?.cancel()
                state.retryTask = nil
            }
            return changed
        }
        if changed, host != nil { probeSoon() }
    }

    // MARK: Requests

    /// Before a request is sent: one to the main server while it is down fails
    /// at once (the probe excepted).
    func admit(_ request: URLRequest) async throws {
        guard isMainServer(request.url) else { return }
        if isSimulatingOutage {
            try await Task.sleep(for: .milliseconds(300))
            throw URLError(.cannotConnectToHost)
        }
        guard request.value(forHTTPHeaderField: Self.probeHeader) == nil, isOffline else { return }
        throw URLError(.cannotConnectToHost)
    }

    /// After a request: any answer means the server is up; a connection failure
    /// is checked with a probe.
    func report(_ request: URLRequest, error: (any Error)?) {
        guard isMainServer(request.url), request.value(forHTTPHeaderField: Self.probeHeader) == nil else { return }
        guard let error else {
            setOffline(false)
            return
        }
        if Self.isConnectionFailure(error), !isOffline { probeSoon() }
    }

    nonisolated static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // MARK: Probing

    private var isSimulatingOutage: Bool {
        state.withLock { state in
            guard let until = state.simulatedUntil else { return false }
            if Date() < until { return true }
            state.simulatedUntil = nil
            return false
        }
    }

    /// Probe now unless one is already running.
    func probeSoon() {
        let start = state.withLock { state -> Bool in
            guard !state.isProbing, state.baseURL != nil else { return false }
            state.isProbing = true
            return true
        }
        guard start else { return }
        Task.detached { [self] in
            let up = await probe()
            state.withLock { $0.isProbing = false }
            setOffline(!up)
        }
    }

    private func probe() async -> Bool {
        let (base, token) = state.withLock { ($0.baseURL, $0.token) }
        // The API session's certificate rule (`PlexCertificateDelegate`).
        guard let base, let url = URL(string: "\(base)/identity") else { return false }
        var request = URLRequest(url: url, timeoutInterval: Self.probeTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: Self.probeHeader)
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        do {
            let (_, response) = try await ForegroundGate.shared.data(
                for: request, in: PlexCertificateDelegate.session)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    private func setOffline(_ offline: Bool) {
        let changed = state.withLock { state -> Bool in
            guard state.isOffline != offline else { return false }
            state.isOffline = offline
            return true
        }
        if offline { scheduleRetry() }
        guard changed else { return }
        healthLog.info("[Health] main server \(offline ? "offline" : "back online", privacy: .public)")
        Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private func scheduleRetry() {
        let task = Task.detached { [self] in
            try? await Task.sleep(for: .seconds(Self.retryInterval))
            guard !Task.isCancelled, isOffline else { return }
            probeSoon()
        }
        state.withLock { state in
            state.retryTask?.cancel()
            state.retryTask = task
        }
    }
}

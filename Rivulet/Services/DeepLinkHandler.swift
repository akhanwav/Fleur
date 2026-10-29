// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DeepLinkHandler.swift
//  Rivulet
//
//  Handles deep links from Top Shelf, Siri intents, and other URL schemes
//

import Foundation
import Combine

@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    @Published var pendingPlayback: PlexMetadata?
    @Published var pendingDetail: PlexMetadata?
    /// A title to open whole, from any server or TMDB (the player's end card).
    @Published var pendingDetailItem: MediaItem?

    /// The link waiting for the app to be ready. A newer link replaces it.
    private(set) var heldLink: RivuletLink?

    /// Set by the shell: true once the launch profile gate has passed, false
    /// while a profile picker or PIN prompt withholds content.
    var isShellReady = false {
        didSet { if isShellReady { deliverHeldLink() } }
    }

    // Seams for tests.
    var credentials: () -> (serverURL: String, token: String)? = {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return (serverURL, token)
    }
    var fetch: (_ ratingKey: String, _ serverURL: String, _ token: String) async throws -> PlexMetadata = {
        try await PlexNetworkManager.shared.getMetadata(serverURL: $1, authToken: $2, ratingKey: $0)
    }
    var reconnect: () async -> Void = { await PlexAuthManager.shared.verifyAndFixConnection() }
    var isSignedIn: () -> Bool = { PlexAuthManager.shared.hasCredentials }

    init() {}

    // MARK: - Entry points

    func handle(url: URL) {
        guard let link = RivuletLink(url: url) else { return }
        handle(link)
    }

    func handlePlay(ratingKey: String) {
        handle(RivuletLink(.play, ratingKey: ratingKey))
    }

    func handleDetail(ratingKey: String) {
        handle(RivuletLink(.detail, ratingKey: ratingKey))
    }

    /// Opens a title the app already holds. Never held: it comes from inside
    /// the running app, so the shell is ready.
    func openDetail(_ item: MediaItem) {
        pendingDetailItem = item
    }

    @discardableResult
    func handle(_ link: RivuletLink) -> Task<Void, Never>? {
        // Signed out there is nothing to wait for: holding it would fire at the next sign-in.
        guard isSignedIn() else { return nil }
        heldLink = link
        return deliverHeldLink()
    }

    /// Sign-out: a link held behind the profile prompt must not fire for the next account.
    func dropHeldLink() { heldLink = nil }

    // MARK: - Delivery

    /// Resolves the held link once the shell is ready and a content token
    /// exists. Until then it stays held; the shell calls this again.
    @discardableResult
    func deliverHeldLink() -> Task<Void, Never>? {
        guard isShellReady, let link = heldLink, credentials() != nil else { return nil }
        heldLink = nil
        return Task { await resolve(link) }
    }

    private func resolve(_ link: RivuletLink) async {
        let token = credentials()?.token
        var metadata = await metadata(for: link)
        if metadata == nil {
            // A saved server address that stopped answering (cold launch): reconnect, retry once.
            await reconnect()
            metadata = await self.metadata(for: link)
        }
        // A profile prompt or switch happened while fetching: fetch again as the current profile.
        guard isShellReady, credentials()?.token == token else {
            if heldLink == nil { heldLink = link }
            deliverHeldLink()
            return
        }
        guard let metadata else {
            print("DeepLinkHandler: could not resolve ratingKey \(link.ratingKey)")
            return
        }
        switch link.action {
        case .play: pendingPlayback = metadata
        case .detail: pendingDetail = metadata
        }
    }

    private func metadata(for link: RivuletLink) async -> PlexMetadata? {
        guard let (serverURL, token) = credentials() else { return nil }
        return try? await fetch(link.ratingKey, serverURL, token)
    }
}

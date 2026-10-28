// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexItemServer.swift
//  Rivulet
//
//  The Plex server an item belongs to. Continue Watching lists other servers'
//  items (Alpha's, Diamond's) beside the signed-in server's; each is minted
//  with its own server's provider id, and opening, playing or removing it has
//  to talk to that server, with its own ratingKey and token.
//

import Foundation

@MainActor
enum PlexItemServer {
    /// The item's own Plex server, else the signed-in one.
    static func access(for ref: MediaItemRef) -> (serverURL: String, token: String)? {
        let registry = MediaProviderRegistry.shared
        if let provider = registry.provider(for: ref.providerID) as? PlexProvider {
            return (provider.serverURL, provider.authToken)
        }
        // Another server not reached yet: its ratingKey means nothing on the
        // signed-in one.
        if let main = registry.plexProvider?.id, ref.isPlex, ref.providerID != main { return nil }
        let auth = PlexAuthManager.shared
        guard let url = auth.selectedServerURL, let token = auth.selectedServerToken else { return nil }
        return (url, token)
    }

    /// Another server's provider for this item, nil for the signed-in server's.
    private static func otherServer(for ref: MediaItemRef) -> PlexProvider? {
        let registry = MediaProviderRegistry.shared
        guard let provider = registry.provider(for: ref.providerID) as? PlexProvider,
              provider.id != registry.plexProvider?.id else { return nil }
        return provider
    }

    /// The name of the server a page's own copy is on.
    static func name(for ref: MediaItemRef) -> String? {
        otherServer(for: ref)?.displayName ?? (ref.isPlex ? PlexAuthManager.shared.mainServerName : nil)
    }

    /// The machine id of the server a page's own copy is on, so Ways to Watch
    /// lists the others and not that one again.
    static func machineId(for ref: MediaItemRef) -> String? {
        otherServer(for: ref).map { String($0.id.dropFirst("plex:".count)) } ?? DetailCopySelection.mainMachineId
    }
}

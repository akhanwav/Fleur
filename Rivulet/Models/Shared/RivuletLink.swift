// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RivuletLink.swift
//  Rivulet
//
//  The one definition of a `rivulet://` deep link. Compiled into the app AND
//  the Top Shelf extension, so the builder and the parser cannot drift.
//

import Foundation

struct RivuletLink: Equatable, Sendable {
    enum Action: String, Sendable {
        case play      // start playback at the resume point
        case detail    // open the item's detail
    }

    static let scheme = "rivulet"

    let action: Action
    let ratingKey: String
    /// The server the item was cached from. Informational: the app resolves
    /// against the selected server.
    var server: String?

    init(_ action: Action, ratingKey: String, server: String? = nil) {
        self.action = action
        self.ratingKey = ratingKey
        self.server = server
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let action = url.host.flatMap(Action.init(rawValue:)),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let ratingKey = items.first(where: { $0.name == "ratingKey" })?.value,
              !ratingKey.isEmpty else { return nil }
        self.init(action, ratingKey: ratingKey,
                  server: items.first(where: { $0.name == "server" })?.value)
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.queryItems = [URLQueryItem(name: "ratingKey", value: ratingKey)]
        if let server { components.queryItems?.append(URLQueryItem(name: "server", value: server)) }
        return components.url
    }
}

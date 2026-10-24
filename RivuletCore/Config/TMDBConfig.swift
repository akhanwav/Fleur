// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBConfig.swift
//  Rivulet
//
//  Centralized configuration for direct TMDB API access.
//

import Foundation

enum TMDBConfig {
    /// TMDB's own REST API. Calls carry this account's own API Read Access
    /// Token (`Secrets.tmdbAccessToken`) and go straight to TMDB — there is
    /// no proxy in front of them.
    static let apiBaseURL = URL(string: "https://api.themoviedb.org/3")!

    /// Cache TTL for TMDB responses when stored locally (in seconds).
    static let localCacheTTL: TimeInterval = 60 * 60 * 24 * 30  // 30 days

    /// Builds an authorized GET request against `apiBaseURL` for `path`
    /// (e.g. `"movie/\(id)/keywords"`, no leading slash). Deliberately a
    /// plain request, never routed through `URLSession+Attested`: App
    /// Attest is scoped to this app's own Cloudflare Workers, and sending
    /// an assertion to a third-party host like TMDB would leak it to a
    /// server that has no business seeing one.
    static func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest? {
        guard let url = URL(string: path, relativeTo: apiBaseURL) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let finalURL = components?.url else { return nil }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(Secrets.tmdbAccessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

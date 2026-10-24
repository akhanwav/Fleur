// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsShowIDResolver.swift
//  Rivulet
//
//  Resolves a show's TMDB id for Insights when Plex didn't give us a direct
//  tmdb:// guid. Modern Plex agents store a plex:// or tvdb:// grandparent
//  guid on episodes, with the real external ids (tvdb://, imdb://) in the
//  `Guid` array — so an episode's show TMDB id often can't be read straight
//  off `grandparentGuid`. This bridges tvdb/imdb -> tmdb via TMDB's own
//  `/find` endpoint, caching per show so it's one lookup, not one per episode.
//

import Foundation

actor InsightsShowIDResolver {
    static let shared = InsightsShowIDResolver()

    private let session: URLSession
    private let baseURL: URL
    // Cache keyed by the external id we looked up ("tvdb:409104" / "imdb:tt...")
    // so repeated episodes of the same show don't re-hit the network. nil is
    // cached too (a negative result) to avoid hammering find for an unmatchable
    // show every episode.
    private var cache: [String: Int?] = [:]

    init(baseURL: URL = TMDBConfig.apiBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Best show TMDB id from the given external ids: a direct tmdb id wins
    /// (no network), else resolve tvdb -> tmdb, else imdb -> tmdb. `nil` if none
    /// resolve.
    func resolve(_ ids: ShowExternalIDs) async -> Int? {
        if let tmdb = ids.tmdb { return tmdb }
        if let tvdb = ids.tvdb, let id = await find(external: String(tvdb), source: "tvdb_id", cacheKey: "tvdb:\(tvdb)") {
            return id
        }
        if let imdb = ids.imdb, let id = await find(external: imdb, source: "imdb_id", cacheKey: "imdb:\(imdb)") {
            return id
        }
        return nil
    }

    /// Hit TMDB's `/find/{externalId}?external_source={source}` and return
    /// the first TV result's TMDB id. Result (including nil) cached per
    /// external id.
    private func find(external: String, source: String, cacheKey: String) async -> Int? {
        if let cached = cache[cacheKey] { return cached }
        let id = await performFind(external: external, source: source)
        cache[cacheKey] = id
        return id
    }

    private func performFind(external: String, source: String) async -> Int? {
        guard let encoded = external.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "find/\(encoded)", relativeTo: baseURL) else { return nil }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        comps?.queryItems = [URLQueryItem(name: "external_source", value: source)]
        guard let finalURL = comps?.url else { return nil }

        var req = URLRequest(url: finalURL)
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue("Bearer \(Secrets.tmdbAccessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(FindResponse.self, from: data) else {
            return nil
        }
        return decoded.tvResults.first?.id
    }

    private struct FindResponse: Decodable {
        let tvResults: [Result]
        struct Result: Decodable { let id: Int }
        enum CodingKeys: String, CodingKey { case tvResults = "tv_results" }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AniListClient.swift
//  Rivulet
//
//  English voice casts from AniList's public GraphQL API (anilist.co):
//  each entry's characters with their English voice actor and photo.
//
//  Used under AniList's terms (docs.anilist.co/guide/terms-of-use): free for
//  non-commercial use, no bulk collection. A page asks only for the entries
//  it shows, in one batched query, and each entry is kept on disk for 30
//  days. The API allows 30 requests a minute while degraded (90 normally),
//  per client, so requests are spaced to stay under that, and a 429's
//  Retry-After is honoured. Cloudflare in front of it refuses some generic
//  clients, so requests carry a named user agent.
//

import Foundation
import os

nonisolated private let aniListLog = Logger(subsystem: "com.rivulet.app", category: "AniList")

actor AniListClient {
    static let shared = AniListClient()

    nonisolated struct VoiceActor: Codable, Hashable, Sendable {
        let id: Int
        let name: String
        let image: URL?
    }

    nonisolated struct Character: Codable, Equatable, Sendable {
        /// MAIN, SUPPORTING or BACKGROUND.
        let role: String
        let name: String
        /// The character's English voice actor, when AniList has one.
        let actor: VoiceActor?
    }

    private nonisolated struct Cached: Codable {
        let fetchedAt: Date
        let characters: [Character]
    }

    static let endpoint = URL(string: "https://graphql.anilist.co")!
    static let cacheLifetime: TimeInterval = 30 * 86_400
    /// 30 a minute, with room to spare.
    static let spacing: Duration = .milliseconds(2_100)

    private var lastRequest: ContinuousClock.Instant?
    private var blockedUntil: Date?

    private var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AniListCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Each entry's characters, from the cache or one query for the rest.
    /// An entry missing from the answer is absent from the result.
    func characters(for ids: [Int]) async -> [Int: [Character]] {
        var result: [Int: [Character]] = [:]
        var missing: [Int] = []
        for id in ids {
            if let cached = cached(id) { result[id] = cached } else { missing.append(id) }
        }
        guard !missing.isEmpty, let fetched = await fetch(missing) else { return result }
        for (id, characters) in fetched {
            result[id] = characters
            let entry = Cached(fetchedAt: Date(), characters: characters)
            try? JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        }
        return result
    }

    private func cached(_ id: Int) -> [Character]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")),
              let entry = try? JSONDecoder().decode(Cached.self, from: data),
              Date().timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime else { return nil }
        return entry.characters
    }

    private static let query = """
    query($ids: [Int]) { Page(perPage: 50) { media(id_in: $ids, type: ANIME) { id
      characters(sort: [ROLE, RELEVANCE], perPage: 25) { edges { role node { name { full } }
        voiceActors(language: ENGLISH, sort: [RELEVANCE]) { id name { full } image { large } } } } } } }
    """

    private func fetch(_ ids: [Int]) async -> [Int: [Character]]? {
        if let blockedUntil, blockedUntil > Date() { return nil }
        if let lastRequest {
            let wait = Self.spacing - (ContinuousClock.now - lastRequest)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        lastRequest = .now
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": ["ids": ids]])
        do {
            let (data, response) = try await ForegroundGate.shared.data(for: request, in: .shared, always: true)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429 {
                let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
                blockedUntil = Date().addingTimeInterval(retry)
                aniListLog.error("[AniList] rate limited for \(Int(retry), privacy: .public)s")
                return nil
            }
            guard http?.statusCode == 200 else {
                aniListLog.error("[AniList] answered \(http?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            return try Self.parse(data)
        } catch {
            aniListLog.error("[AniList] failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        return "Rivulet/\(version) (Apple TV)"
    }

    // MARK: - Pure

    private nonisolated struct Response: Decodable {
        struct DataBlock: Decodable { let Page: PageBlock }
        struct PageBlock: Decodable { let media: [Media] }
        struct Media: Decodable {
            let id: Int
            let characters: Characters
        }
        struct Characters: Decodable { let edges: [Edge] }
        struct Edge: Decodable {
            let role: String?
            let node: Node
            let voiceActors: [Staff]
        }
        struct Node: Decodable { let name: Name }
        struct Name: Decodable { let full: String? }
        struct Staff: Decodable {
            let id: Int
            let name: Name
            let image: Image?
        }
        struct Image: Decodable { let large: URL? }
        let data: DataBlock
    }

    /// Each entry's characters, with the first English voice actor listed
    /// for each. AniList's placeholder portrait counts as no photo.
    nonisolated static func parse(_ data: Data) throws -> [Int: [Character]] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result: [Int: [Character]] = [:]
        for media in response.data.Page.media {
            result[media.id] = media.characters.edges.compactMap { edge in
                guard let name = edge.node.name.full else { return nil }
                let actor = edge.voiceActors.first.flatMap { staff -> VoiceActor? in
                    guard let full = staff.name.full else { return nil }
                    let image = staff.image?.large.flatMap { $0.lastPathComponent.hasPrefix("default") ? nil : $0 }
                    return VoiceActor(id: staff.id, name: full, image: image)
                }
                return Character(role: edge.role ?? "BACKGROUND", name: name, actor: actor)
            }
        }
        return result
    }
}

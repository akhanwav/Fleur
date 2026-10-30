// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DubDatabaseClient.swift
//  Rivulet
//
//  English dub casts of non-English animation outside anime, from The
//  Dubbing Database (dubdb.fandom.com), a community wiki under CC BY-SA.
//  TMDB and Wikidata have none: measured on 21 French, Spanish and Danish
//  animated titles, TMDB's credits held 0 of 28 known English voices and
//  Wikidata had English-tagged voices for 1. This wiki had English casts for 8.
//
//  Each dub is its own page ("Arco (English)") with a cast of
//  `{{Cast list/character|Iris |actor = [[Romy Fay]]}}` entries, and an
//  infobox naming its language and its work (`media = Arco`), which the
//  original's page names too. Pages carry no TMDB or IMDb id, so a title is
//  matched strictly, or not at all, because a wrong cast is worse than none:
//  - the original's page, by TMDB's original or English title, must be in
//    the original language, with TMDB's year (±1) in its release field;
//  - the English page must say English and name the same work.
//  Measured: looser matching (any page linking to the original) put Sonic's
//  and Bratz's casts on Spanish and French films.
//
//  Read through the wiki's MediaWiki API, one request a second, with a named
//  user agent; each title's answer (an empty one included) is cached 30 days.
//

import Foundation
import os

nonisolated private let dubDatabaseLog = Logger(subsystem: "com.rivulet.app", category: "DubDatabase")

actor DubDatabaseClient {
    static let shared = DubDatabaseClient()

    nonisolated struct Role: Codable, Equatable, Sendable {
        let character: String
        let actor: String
    }

    /// The title to find: TMDB's original title and language, English title
    /// and year.
    nonisolated struct Title: Equatable, Sendable {
        let tmdbId: Int
        let isMovie: Bool
        let original: TMDBOriginalTitle
    }

    private nonisolated struct Cached: Codable {
        let fetchedAt: Date
        let roles: [Role]
    }

    static let endpoint = URL(string: "https://dubdb.fandom.com/api.php")!
    static let cacheLifetime: TimeInterval = 30 * 86_400
    static let spacing: Duration = .seconds(1)

    private var lastRequest: ContinuousClock.Instant?

    private var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DubDatabase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The English dub's cast, in the page's order; empty when there is no
    /// page that matches strictly. nil when the wiki could not be read.
    func englishCast(for title: Title) async -> [Role]? {
        let file = directory.appendingPathComponent("\(title.isMovie ? "movie" : "tv")-\(title.tmdbId).json")
        if let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode(Cached.self, from: data),
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return cached.roles
        }
        guard let roles = await find(title) else { return nil }
        try? JSONEncoder().encode(Cached(fetchedAt: Date(), roles: roles)).write(to: file, options: .atomic)
        return roles
    }

    private func find(_ title: Title) async -> [Role]? {
        let original = title.original
        let names = Self.unique([original.title, original.englishTitle,
                                 "\(original.title) (English)", "\(original.englishTitle) (English)"])
        guard var pages = await contents(of: names) else { return nil }
        let languageName = Self.languageName(original.language)
        // The original's page: one of the titles, or the work an English page
        // among them names ("Ernest & Celestine" names "Ernest et Célestine").
        var source = pages.first { Self.isOriginal($0, languageName: languageName, year: original.year) }
        if source == nil {
            let read = Set(pages.map(\.title))
            let named = Self.unique(pages.compactMap { Self.workTitle(of: $0.text) }).filter { !read.contains($0) }
            if !named.isEmpty, let more = await contents(of: named) {
                pages += more
                source = more.first { Self.isOriginal($0, languageName: languageName, year: original.year) }
            }
        }
        guard let source else { return [] }
        if let dub = pages.first(where: { Self.isEnglishDub($0, of: source) }) {
            return Self.roles(dub.text)
        }
        // Then the pages linking to the original that look like its English dub.
        guard let links = await backlinks(to: source.title) else { return nil }
        let read = Set(pages.map(\.title))
        let candidates = links.filter { (name: String) -> Bool in
            let looksEnglish = name.localizedCaseInsensitiveContains("English") || name == original.englishTitle
            return looksEnglish && !read.contains(name)
        }
        guard !candidates.isEmpty, let more = await contents(of: Array(candidates.prefix(50))) else { return [] }
        return more.first { Self.isEnglishDub($0, of: source) }.map { Self.roles($0.text) } ?? []
    }

    // MARK: - API

    nonisolated struct Page: Equatable, Sendable {
        let title: String
        let text: String
    }

    private func contents(of titles: [String]) async -> [Page]? {
        guard let json = await call([
            "action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
            "redirects": "1", "titles": titles.joined(separator: "|"),
        ]) else { return nil }
        let pages = ((json["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []
        return pages.compactMap { page in
            guard page["missing"] == nil, let title = page["title"] as? String,
                  let revision = (page["revisions"] as? [[String: Any]])?.first,
                  let main = (revision["slots"] as? [String: Any])?["main"] as? [String: Any],
                  let text = main["content"] as? String else { return nil }
            return Page(title: title, text: text)
        }
    }

    private func backlinks(to title: String) async -> [String]? {
        guard let json = await call([
            "action": "query", "list": "backlinks", "bltitle": title, "blnamespace": "0", "bllimit": "500",
        ]) else { return nil }
        let links = ((json["query"] as? [String: Any])?["backlinks"] as? [[String: Any]]) ?? []
        return links.compactMap { $0["title"] as? String }
    }

    private func call(_ parameters: [String: String]) async -> [String: Any]? {
        if let lastRequest {
            let wait = Self.spacing - (ContinuousClock.now - lastRequest)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        lastRequest = .now
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (parameters.merging(["format": "json", "formatversion": "2"]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        request.setValue("Rivulet/\(version) (Apple TV)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await ForegroundGate.shared.data(for: request, in: .shared, always: true)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                dubDatabaseLog.error("[DubDatabase] answered \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            dubDatabaseLog.error("[DubDatabase] failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pure

    private nonisolated static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "French" for "fr", as the wiki names languages.
    nonisolated static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// The first value of an infobox or dubbing-template field, without its
    /// notes, references and link brackets.
    nonisolated static func field(_ name: String, in text: String) -> String? {
        let pattern = "(?m)^\\s*\\|\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = clean(String(text[range]))
        return value.isEmpty ? nil : value
    }

    /// Wiki markup down to its text: templates and references out, a link to
    /// its label.
    nonisolated static func clean(_ markup: String) -> String {
        var text = markup
        text = text.replacingOccurrences(of: "<ref[^>]*/>|<ref[^>]*>.*?</ref>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\{\\{[^{}]*\\}\\}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The work a page belongs to: a dub page's `film`/`series`, else the
    /// infobox's `media`.
    nonisolated static func workTitle(of text: String) -> String? {
        field("film", in: text) ?? field("series", in: text) ?? field("media", in: text)
    }

    /// The original's page: in the original language, with TMDB's year (±1)
    /// among its release years when it lists any.
    nonisolated static func isOriginal(_ page: Page, languageName: String, year: Int?) -> Bool {
        guard let language = field("language", in: page.text),
              language.localizedCaseInsensitiveContains(languageName) else { return false }
        guard let year else { return true }
        let release = field("release", in: page.text) ?? field("first_aired", in: page.text) ?? ""
        let years = release.matches(of: /\b(?:19|20)\d{2}\b/).compactMap { Int($0.output) }
        return years.isEmpty || years.contains { abs($0 - year) <= 1 }
    }

    /// The original's English dub: in English, naming the same work.
    nonisolated static func isEnglishDub(_ page: Page, of source: Page) -> Bool {
        guard page.title != source.title,
              let language = field("language", in: page.text),
              language.localizedCaseInsensitiveContains("English") else { return false }
        let work = workTitle(of: page.text)?.lowercased()
        let names = Set([source.title, field("media", in: source.text), field("title", in: source.text)]
            .compactMap { $0?.lowercased() })
        let media = field("media", in: page.text)?.lowercased()
        return (work.map(names.contains) ?? false) || (media.map(names.contains) ?? false)
    }

    /// The page's cast in order: each character with its first actor.
    /// Split at each entry's own template, not at every `{{`: an actor line
    /// can hold a template of its own (`{{flag icon|US}} [[Gena Rowlands]]`).
    nonisolated static func roles(_ text: String) -> [Role] {
        let starts = text.ranges(of: /\{\{\s*[Cc]ast[ _]list\/character\s*\|/)
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].lowerBound : text.endIndex
            let body = String(text[start.upperBound..<end])
            let character = clean(String(body.prefix { $0 != "\n" && $0 != "|" }))
            guard let actor = field("actor", in: body) ?? field("actor1", in: body) else { return nil }
            return Role(character: character, actor: actor)
        }
    }
}

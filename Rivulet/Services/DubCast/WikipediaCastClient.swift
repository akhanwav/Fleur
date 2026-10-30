// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WikipediaCastClient.swift
//  Rivulet
//
//  English dub casts from English Wikipedia (CC BY-SA), the third source
//  after AniList and The Dubbing Database. Many articles on non-English
//  animation give the cast as a table with a column per language (Arco:
//  Character, then "Voice actor" over French and English). Measured on 20
//  French, Spanish and Danish titles: 8 have a column headed English, 5 of
//  them dubs The Dubbing Database lacks.
//
//  Matched by id, never by title: TMDB names the title's Wikidata item, and
//  Wikidata names its English Wikipedia article. Only a rendered table with a
//  Character (or Role) column and a column whose header says English is read;
//  a column headed only "Dub Actor" is not, nor a cast given as a list of the
//  original actors (Persepolis). Shows rarely have such a table.
//
//  One request a second to each host, the app's user agent, and a 429's
//  Retry-After honoured. Each title's answer, an empty one included, is
//  cached 30 days.
//

import Foundation
import os

nonisolated private let wikipediaCastLog = Logger(subsystem: "com.rivulet.app", category: "WikipediaCast")

actor WikipediaCastClient {
    static let shared = WikipediaCastClient()

    typealias Role = EnglishDubCast.Role

    private nonisolated struct Cached: Codable {
        let fetchedAt: Date
        let roles: [Role]
    }

    static let cacheLifetime: TimeInterval = 30 * 86_400
    static let spacing: Duration = .seconds(1)

    private var lastRequest: [String: ContinuousClock.Instant] = [:]
    private var blockedUntil: [String: Date] = [:]

    private var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WikipediaCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The English cast from the title's Wikipedia article; empty when the
    /// article has no table that qualifies. nil when it could not be read.
    func englishCast(tmdbId: Int, isMovie: Bool) async -> [Role]? {
        let file = directory.appendingPathComponent("\(isMovie ? "movie" : "tv")-\(tmdbId).json")
        if let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode(Cached.self, from: data),
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return cached.roles
        }
        guard let roles = await find(tmdbId: tmdbId, isMovie: isMovie) else { return nil }
        try? JSONEncoder().encode(Cached(fetchedAt: Date(), roles: roles)).write(to: file, options: .atomic)
        return roles
    }

    private func find(tmdbId: Int, isMovie: Bool) async -> [Role]? {
        guard let item = await TMDBClient.shared.wikidataID(tmdbId: tmdbId, isMovie: isMovie) else { return [] }
        guard let entities = await call("www.wikidata.org", [
            "action": "wbgetentities", "ids": item, "props": "sitelinks", "sitefilter": "enwiki",
        ]) else { return nil }
        let entity = (entities["entities"] as? [String: Any])?[item] as? [String: Any]
        let sitelinks = entity?["sitelinks"] as? [String: Any]
        guard let article = (sitelinks?["enwiki"] as? [String: Any])?["title"] as? String else { return [] }

        guard let parsed = await call("en.wikipedia.org", [
            "action": "parse", "page": article, "prop": "sections", "redirects": "1",
        ]) else { return nil }
        let sections = ((parsed["parse"] as? [String: Any])?["sections"] as? [[String: Any]]) ?? []
        let castSections = sections.filter {
            (($0["line"] as? String) ?? "").range(of: "cast|voice", options: [.regularExpression, .caseInsensitive]) != nil
        }.compactMap { $0["index"] as? String }
        for index in castSections.prefix(2) {
            guard let section = await call("en.wikipedia.org", [
                "action": "parse", "page": article, "prop": "text", "section": index, "redirects": "1",
                "disableeditsection": "1", "disablelimitreport": "1",
            ]) else { return nil }
            let html = (section["parse"] as? [String: Any])?["text"] as? String ?? ""
            let roles = Self.roles(inHTML: html)
            if !roles.isEmpty { return roles }
        }
        return []
    }

    private func call(_ host: String, _ parameters: [String: String]) async -> [String: Any]? {
        if let until = blockedUntil[host], until > Date() { return nil }
        if let last = lastRequest[host] {
            let wait = Self.spacing - (ContinuousClock.now - last)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        lastRequest[host] = .now
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/w/api.php"
        components.queryItems = (parameters.merging(["format": "json", "formatversion": "2"]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(EnglishDubCast.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await ForegroundGate.shared.data(for: request, in: .shared, always: true)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429 {
                let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
                blockedUntil[host] = Date().addingTimeInterval(retry)
                wikipediaCastLog.error("[WikipediaCast] \(host, privacy: .public) rate limited for \(Int(retry), privacy: .public)s")
                return nil
            }
            guard http?.statusCode == 200 else {
                wikipediaCastLog.error("[WikipediaCast] \(host, privacy: .public) answered \(http?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            wikipediaCastLog.error("[WikipediaCast] failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pure: rendered cast tables

    nonisolated struct Cell: Equatable {
        let lines: [String]
        let isHeader: Bool
        let isRowHeader: Bool
        var text: String { lines.joined(separator: " ") }
    }

    /// The English cast of the first wikitable that has a Character (or
    /// Role) column and a column whose header says English.
    nonisolated static func roles(inHTML html: String) -> [Role] {
        for table in tables(in: html) {
            let roles = roles(inTable: grid(table))
            if !roles.isEmpty { return roles }
        }
        return []
    }

    nonisolated static func tables(in html: String) -> [String] {
        html.matches(of: /(?s)<table[^>]*class="[^"]*wikitable[^"]*"[^>]*>(.*?)<\/table>/).map { String($0.output.1) }
    }

    /// The table as rows of cells, row and column spans expanded so every
    /// row has a cell in every column it spans.
    nonisolated static func grid(_ table: String) -> [[Cell]] {
        var grid: [[Cell]] = []
        var carried: [Int: (cell: Cell, rows: Int)] = [:]
        for row in table.matches(of: /(?s)<tr[^>]*>(.*?)<\/tr>/) {
            var cells: [Cell] = []
            var column = 0
            func takeCarried() {
                while let carry = carried[column] {
                    cells.append(carry.cell)
                    carried[column] = carry.rows > 1 ? (carry.cell, carry.rows - 1) : nil
                    column += 1
                }
            }
            for match in String(row.output.1).matches(of: /(?s)<(th|td)\b([^>]*)>(.*?)<\/\1>/) {
                takeCarried()
                let attributes = String(match.output.2)
                let cell = Cell(lines: lines(String(match.output.3)), isHeader: match.output.1 == "th",
                                isRowHeader: attributes.contains("scope=\"row\""))
                let rows = span("rowspan", in: attributes), columns = span("colspan", in: attributes)
                for _ in 0..<columns {
                    cells.append(cell)
                    if rows > 1 { carried[column] = (cell, rows - 1) }
                    column += 1
                }
            }
            takeCarried()
            if !cells.isEmpty { grid.append(cells) }
        }
        return grid
    }

    nonisolated static func roles(inTable grid: [[Cell]]) -> [Role] {
        // Header rows: the leading rows of column headers only.
        let headerCount = grid.prefix { row in row.allSatisfy { $0.isHeader && !$0.isRowHeader } }.count
        guard headerCount > 0 else { return [] }
        let width = grid.map(\.count).max() ?? 0
        let headers = (0..<width).map { column in
            grid.prefix(headerCount).compactMap { $0.indices.contains(column) ? $0[column].text : nil }
                .joined(separator: " ").lowercased()
        }
        guard let characterColumn = headers.firstIndex(where: { $0.contains("character") || $0.contains("role") }),
              let englishColumn = headers.firstIndex(where: { $0.contains("english") }),
              characterColumn != englishColumn else { return [] }
        var roles: [Role] = []
        for row in grid.dropFirst(headerCount) {
            guard row.indices.contains(characterColumn), row.indices.contains(englishColumn) else { continue }
            // Checkered Ninja names the Danish character in brackets.
            let character = row[characterColumn].lines.first.map(withoutNote) ?? ""
            guard var actor = row[englishColumn].lines.first.map(withoutNote), !actor.isEmpty,
                  !["—", "–", "-", "n/a", "tba", "tbd", "none", "uncredited"].contains(actor.lowercased())
            else { continue }
            // A cell of surnames ("Portman", for Mikki) names actors listed in full above.
            if !actor.contains(" "), let full = roles.map(\.actor).first(where: { $0.hasSuffix(" " + actor) }) {
                actor = full
            }
            roles.append(Role(character: character, actor: actor))
        }
        return roles
    }

    /// "Sophie Mas (young)" → "Sophie Mas".
    nonisolated static func withoutNote(_ name: String) -> String {
        name.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func span(_ name: String, in attributes: String) -> Int {
        guard let range = attributes.range(of: "\(name)=\"?\\d+", options: [.regularExpression, .caseInsensitive])
        else { return 1 }
        return max(1, Int(attributes[range].filter(\.isNumber)) ?? 1)
    }

    /// A cell's text, a line per `<br>`, without references or markup.
    nonisolated static func lines(_ cell: String) -> [String] {
        var text = cell
        text = text.replacingOccurrences(of: "(?s)<sup[^>]*class=\"[^\"]*reference[^\"]*\"[^>]*>.*?</sup>", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text).components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, value) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out.replacing(/&#(x?)([0-9A-Fa-f]+);/) { match in
            let value = UInt32(match.output.2, radix: match.output.1.isEmpty ? 10 : 16)
            return value.flatMap(Unicode.Scalar.init).map { String($0) } ?? ""
        }
    }
}

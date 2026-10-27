// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchSuggestions.swift
//  Rivulet
//
//  The suggestions row above Search's results: titles from your library index
//  (instant, judged on device) and from TMDB, merged into one ranked list.
//
//  TMDB's own search is literal, so it is asked several ways at once and its
//  answers are judged by `TitleMatcher` like the library's. Measured against
//  TMDB: "the never ending" misses The NeverEnding Story and "the neverending"
//  finds it; "godfathr" finds nothing and "godfat" finds The Godfather; "wall
//  e" finds only people and "wall·e" finds WALL·E; "got" never reaches Game
//  of Thrones without its alias.
//

import Foundation

nonisolated struct SearchSuggestion: Sendable {
    enum Kind: Sendable { case movie, show }

    /// "movie:603", or the normalized title for a library title TMDB never
    /// matched.
    let key: String
    let title: String
    let year: Int?
    let kind: Kind
    var match: TitleMatch
    var popularity: Double
    /// The copy in your library, when you have the title.
    var owned: PlexMetadata?
    var tmdb: TMDBListItem?

    var isOwned: Bool { owned != nil }
}

nonisolated enum SearchSuggestions {
    static let limit = 8
    /// Library titles kept before the merge: enough to rank against TMDB's.
    static let localLimit = 20
    /// TMDB questions per pause in typing, the typed text first.
    static let maxQueries = 6
    /// Unmatched TMDB results whose other titles are read, per query.
    static let alternativeTitleReads = 3
    /// Below this TMDB popularity an unmatched result is not worth a request.
    static let alternativeTitleMinPopularity = 5.0

    // MARK: Ranking

    /// Exact, start-of-title, initials and nickname hits, then typos, then
    /// the query inside a title; within each, titles you have, then TMDB
    /// popularity, then an exact title, then the shorter (closer) title.
    static func rank(_ suggestions: [SearchSuggestion]) -> [SearchSuggestion] {
        let sorted = suggestions.sorted { a, b in
            if a.match.rank != b.match.rank { return a.match.rank < b.match.rank }
            if a.isOwned != b.isOwned { return a.isOwned }
            if a.popularity != b.popularity { return a.popularity > b.popularity }
            if (a.match == .exact) != (b.match == .exact) { return a.match == .exact }
            return a.title.count < b.title.count
        }
        return Array(sorted.prefix(limit))
    }

    /// One list per title: a library copy and a TMDB entry for the same title
    /// become one suggestion with the better match, the copy and the
    /// popularity. Order is kept (first appearance).
    static func merge(_ lists: [SearchSuggestion]...) -> [SearchSuggestion] {
        var order: [String] = []
        var byKey: [String: SearchSuggestion] = [:]
        for suggestion in lists.joined() {
            guard var existing = byKey[suggestion.key] else {
                order.append(suggestion.key)
                byKey[suggestion.key] = suggestion
                continue
            }
            existing.match = min(existing.match, suggestion.match)
            existing.popularity = max(existing.popularity, suggestion.popularity)
            existing.owned = existing.owned ?? suggestion.owned
            existing.tmdb = existing.tmdb ?? suggestion.tmdb
            byKey[suggestion.key] = existing
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: TMDB questions

    /// What TMDB is asked: as typed, any nickname's title, adjacent words
    /// joined ("the neverending"; with "·" too when one is a single letter,
    /// for WALL·E), without a leading article, and the last word cut short
    /// past a likely typo (TMDB finds a word from its start, so "godfathr"
    /// asks "godfat").
    static func tmdbQueries(for raw: String) -> [String] {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var queries = [words.joined(separator: " ")]
        queries += SearchAliases.titles(for: raw)

        var joins = 0
        for i in 0..<(words.count - 1) where joins < 2 {
            // Joined onto an article is never a title ("thenever").
            guard !TitleMatcher.articles.contains(words[i].lowercased()) else { continue }
            let joined = words[..<i] + [words[i] + words[i + 1]] + words[(i + 2)...]
            queries.append(joined.joined(separator: " "))
            if words[i].count == 1 || words[i + 1].count == 1 {
                let dotted = words[..<i] + [words[i] + "·" + words[i + 1]] + words[(i + 2)...]
                queries.append(dotted.joined(separator: " "))
            }
            joins += 1
        }
        if words.count > 1, TitleMatcher.articles.contains(words[0].lowercased()) {
            queries.append(words.dropFirst().joined(separator: " "))
        }
        if let last = words.last, last.count >= 6 {
            let cut = words.dropLast() + [String(last.prefix(max(4, last.count - 2)))]
            queries.append(cut.joined(separator: " "))
        }

        var seen = Set<String>()
        return Array(queries.filter { seen.insert($0.lowercased()).inserted }.prefix(maxQueries))
    }

    static func query(for raw: String) -> TitleMatcher.Query {
        TitleMatcher.Query(raw, aliases: SearchAliases.titles(for: raw))
    }

    // MARK: Sources

    /// Your library's titles for the query. On device, so it answers at once.
    static func library(_ query: TitleMatcher.Query) async -> [SearchSuggestion] {
        await LibraryGUIDIndex.shared.titleMatches(query, limit: localLimit).compactMap { hit in
            let meta = hit.metadata
            let kind: SearchSuggestion.Kind = meta.type == "show" ? .show : .movie
            guard let title = meta.title else { return nil }
            return SearchSuggestion(
                key: hit.tmdbId.map { "\(kind == .movie ? "movie" : "tv"):\($0)" } ?? TitleMatcher.normalize(title),
                title: title, year: meta.year, kind: kind, match: hit.match,
                popularity: 0, owned: meta, tmdb: nil)
        }
    }

    /// TMDB's titles for the query, each judged by `TitleMatcher` and marked
    /// when your library has it. Results matching nothing are dropped, unless
    /// one of the few most popular is found under another of its titles.
    static func tmdb(_ query: TitleMatcher.Query) async -> [SearchSuggestion] {
        let questions = tmdbQueries(for: query.raw)
        let answers = await withTaskGroup(of: (Int, [TMDBListItem]).self) { group in
            for (index, question) in questions.enumerated() {
                group.addTask { (index, await TMDBDiscoverService.shared.searchMulti(question)) }
            }
            var byIndex: [Int: [TMDBListItem]] = [:]
            for await (index, items) in group { byIndex[index] = items }
            // The typed question's answers first, so its order breaks ties.
            return questions.indices.flatMap { byIndex[$0] ?? [] }
        }

        var seen = Set<String>()
        var judged: [(TMDBListItem, TitleMatch)] = []
        var unmatched: [TMDBListItem] = []
        for item in answers where seen.insert("\(item.mediaType.rawValue):\(item.id)").inserted {
            if let match = TitleMatcher.match(TitleMatcher.Keys(title: item.title), query) {
                judged.append((item, match))
            } else {
                unmatched.append(item)
            }
        }
        let worthAsking = unmatched
            .filter { ($0.popularity ?? 0) >= alternativeTitleMinPopularity }
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .prefix(alternativeTitleReads)
        for item in worthAsking {
            let others = await TMDBDiscoverService.shared.alternativeTitles(tmdbId: item.id, type: item.mediaType)
            if let best = others.compactMap({ TitleMatcher.match(TitleMatcher.Keys(title: $0), query) }).min() {
                judged.append((item, best))
            }
        }

        var suggestions: [SearchSuggestion] = []
        for (item, match) in judged {
            let owned = await LibraryGUIDIndex.shared.lookup(tmdbId: item.id, type: item.mediaType)
            // A TMDB title with no poster is a blank tile, and almost always
            // an obscure one.
            guard owned != nil || item.posterPath != nil else { continue }
            suggestions.append(SearchSuggestion(
                key: "\(item.mediaType.rawValue):\(item.id)",
                title: item.title,
                year: item.releaseDate.flatMap { Int($0.prefix(4)) },
                kind: item.mediaType == .movie ? .movie : .show,
                match: match, popularity: item.popularity ?? 0,
                owned: owned, tmdb: item))
        }
        return suggestions
    }
}

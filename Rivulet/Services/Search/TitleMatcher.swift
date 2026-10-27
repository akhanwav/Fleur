// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TitleMatcher.swift
//  Rivulet
//
//  How a title answers a typed search, for Search's suggestions. Pure and
//  synchronous: the library index runs it over every title it holds, and the
//  TMDB results are judged by the same rules, so an owned copy and a TMDB
//  entry rank against each other fairly.
//
//  Both sides are normalized the same way: lowercased, accents and
//  punctuation dropped, spaces removed, "&" read as "and". So "the never
//  ending" meets "The NeverEnding Story", "spider man" meets "Spider-Man" and
//  "wall e" meets "WALL·E".
//

import Foundation

/// How well a title answers a query. Lower is better; `rank` folds the
/// kinds that count as equally good.
nonisolated enum TitleMatch: Int, Sendable, Comparable {
    case exact
    case prefix
    case acronym
    case alias
    /// The start of the title with a typo or two ("godfathr").
    case fuzzy
    case contains

    /// An exact, start-of-title, initials or nickname hit counts as one
    /// kind: a short query mixes them ("got": Gotham and Game of Thrones),
    /// and which of them you have or is popular decides. Then near misses.
    var rank: Int {
        switch self {
        case .exact, .prefix, .acronym, .alias: 0
        case .fuzzy: 1
        case .contains: 2
        }
    }

    static func < (lhs: TitleMatch, rhs: TitleMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum TitleMatcher {
    /// Leading words dropped for "without the article" forms.
    static let articles: Set<String> = ["the", "a", "an"]
    /// Words an acronym may skip: "lotr" is The Lord of the Rings.
    static let acronymSkips: Set<String> = ["the", "of", "and", "a", "an"]

    /// Folded words: lowercased, accents gone, split on anything that is not a
    /// letter or digit, "&" read as "and".
    static func words(_ text: String) -> [String] {
        let folded = text
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return folded
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    static func normalize(_ text: String) -> String { words(text).joined() }

    /// Everything a title is matched by, computed once per title.
    struct Keys: Sendable {
        let full: String
        /// `full` without a leading "the", "a" or "an" ("neverendingstory").
        let bare: String
        let acronyms: Set<String>
        fileprivate let fullBytes: [UInt8]
        fileprivate let bareBytes: [UInt8]

        init(title: String) {
            let words = TitleMatcher.words(title)
            full = words.joined()
            let bareWords = words.count > 1 && TitleMatcher.articles.contains(words[0])
                ? Array(words.dropFirst()) : words
            bare = bareWords.joined()
            fullBytes = Array(full.utf8)
            bareBytes = Array(bare.utf8)

            // The whole title and each part of it ("Law & Order: Special
            // Victims Unit" is also "svu"), with every word, without a leading
            // article, and without the small words.
            var acronyms = Set<String>()
            let parts = title.split(separator: ":")
            for segment in [Substring(title)] + (parts.count > 1 ? parts : []) {
                let segmentWords = TitleMatcher.words(String(segment))
                guard segmentWords.count >= 2 else { continue }
                acronyms.insert(Self.initials(segmentWords))
                if TitleMatcher.articles.contains(segmentWords[0]) {
                    acronyms.insert(Self.initials(Array(segmentWords.dropFirst())))
                }
                let content = segmentWords.filter { !TitleMatcher.acronymSkips.contains($0) }
                if content.count >= 2 { acronyms.insert(Self.initials(content)) }
            }
            self.acronyms = acronyms.filter { $0.count >= 2 }
        }

        private static func initials(_ words: [String]) -> String {
            String(words.compactMap(\.first))
        }
    }

    /// A typed query, prepared once per keystroke.
    struct Query: Sendable {
        let raw: String
        let normalized: String
        /// Without a leading article, when it had one.
        let bare: String
        /// Normalized titles the query is a known nickname for.
        let aliases: [String]
        /// One short word: may be initials ("dbz", "lotr").
        let mayBeAcronym: Bool
        fileprivate let bytes: [UInt8]

        init(_ text: String, aliases: [String] = []) {
            raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = TitleMatcher.words(raw)
            normalized = words.joined()
            bare = words.count > 1 && TitleMatcher.articles.contains(words[0])
                ? words.dropFirst().joined() : normalized
            self.aliases = aliases.map(TitleMatcher.normalize).filter { !$0.isEmpty }
            mayBeAcronym = words.count == 1 && (2...6).contains(normalized.count)
            bytes = Array(normalized.utf8)
        }
    }

    /// The best way `keys` answers `query`, or nil when it does not.
    static func match(_ keys: Keys, _ query: Query) -> TitleMatch? {
        let q = query.normalized
        guard !q.isEmpty, !keys.full.isEmpty else { return nil }
        // "the never ending" is not exactly "Never Ending": an article on one
        // side only makes it a start-of-title match at best.
        if keys.full == q || keys.bare == q { return .exact }
        if keys.full.hasPrefix(q) || keys.bare.hasPrefix(q) || keys.bare.hasPrefix(query.bare) { return .prefix }
        if query.mayBeAcronym, keys.acronyms.contains(q) { return .acronym }
        if query.aliases.contains(where: { keys.full.hasPrefix($0) || keys.bare.hasPrefix($0) }) { return .alias }
        if isNearPrefix(query.bytes, of: keys.bareBytes) || isNearPrefix(query.bytes, of: keys.fullBytes) {
            return .fuzzy
        }
        if q.count >= 3, keys.full.contains(q) { return .contains }
        return nil
    }

    /// Typos allowed for a query of this length: none under five letters
    /// (too many short words are one edit apart), one up to eight, then two.
    static func allowedTypos(forLength length: Int) -> Int {
        switch length {
        case ..<5: 0
        case ..<9: 1
        default: 2
        }
    }

    /// True when the title starts with the query give or take a typo or two
    /// (a missing, extra, wrong or swapped letter). The first letter has to
    /// match: it prunes almost every title cheaply, and a first-letter typo
    /// is rare.
    private static func isNearPrefix(_ query: [UInt8], of title: [UInt8]) -> Bool {
        let budget = allowedTypos(forLength: query.count)
        guard budget > 0, let first = query.first, title.first == first,
              title.count >= query.count - budget else { return false }
        let low = max(1, query.count - budget)
        let high = min(title.count, query.count + budget)
        guard low <= high else { return false }
        for length in low...high where distance(query, title[0..<length], limit: budget) <= budget {
            return true
        }
        return false
    }

    /// Optimal string alignment distance (Damerau–Levenshtein, adjacent swaps
    /// count once), giving up past `limit`.
    static func distance(_ a: [UInt8], _ b: ArraySlice<UInt8>, limit: Int) -> Int {
        let b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}

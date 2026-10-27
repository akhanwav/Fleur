// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchAliases.swift
//  Rivulet
//
//  Nicknames Search understands. Plain initials need no entry when the title
//  is in your library ("dbz" finds Dragon Ball Z by its initials); an entry
//  is for a nickname that is not plain initials ("svu", "tlou"), and for a
//  well-known one TMDB's own search does not find ("got", "lotr"), since
//  only a title TMDB returns can be judged by its initials.
//
//  To add one: the nickname as typed, then the title or titles it means.
//  Both sides are normalized, so case and punctuation do not matter.
//

nonisolated enum SearchAliases {
    static let table: [String: [String]] = [
        "ahs": ["American Horror Story"],
        "aot": ["Attack on Titan"],
        "atla": ["Avatar: The Last Airbender"],
        "b99": ["Brooklyn Nine-Nine"],
        "bcs": ["Better Call Saul"],
        "brba": ["Breaking Bad"],
        "dbz": ["Dragon Ball Z"],
        "ds9": ["Star Trek: Deep Space Nine"],
        "fma": ["Fullmetal Alchemist"],
        "got": ["Game of Thrones"],
        "gotg": ["Guardians of the Galaxy"],
        "himym": ["How I Met Your Mother"],
        "hotd": ["House of the Dragon"],
        "iasip": ["It's Always Sunny in Philadelphia"],
        "jjk": ["Jujutsu Kaisen"],
        "lotr": ["The Lord of the Rings"],
        "sunny": ["It's Always Sunny in Philadelphia"],
        "svu": ["Law & Order: Special Victims Unit"],
        "tbbt": ["The Big Bang Theory"],
        "tlou": ["The Last of Us"],
        "tng": ["Star Trek: The Next Generation"],
        "twd": ["The Walking Dead"]
    ]

    /// The titles a query is a nickname for, if any.
    static func titles(for query: String) -> [String] {
        table[TitleMatcher.normalize(query)] ?? []
    }
}

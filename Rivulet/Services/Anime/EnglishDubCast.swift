// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EnglishDubCast.swift
//  Rivulet
//
//  The detail page's English Dub Cast row: an anime title's English voice
//  actors and their characters, from AniList (`AniListClient`) through
//  Fribb's id map (`AnimeIDMap`).
//
//  Shown only for animation that some copy on the servers can play in
//  English: an English audio track on any copy of a film or episode, or on
//  the episode Play would start for any copy of a show. A season or an
//  episode page lists its own season's entry; a show page combines every
//  entry, main characters first, each actor once.
//

import Foundation

nonisolated enum EnglishDubCast {

    /// One actor in the row, with every character they voice in it.
    struct Credit: Equatable, Sendable {
        let actor: AniListClient.VoiceActor
        let characters: [String]
    }

    /// The row's length: AniList's top characters across a few entries.
    static let limit = 30

    /// Main characters of every entry, then supporting, then background, in
    /// entry order, each actor once with all their characters.
    static func combine(_ entries: [[AniListClient.Character]], limit: Int = limit) -> [Credit] {
        var order: [AniListClient.VoiceActor] = []
        var characters: [Int: [String]] = [:]
        func rank(_ role: String) -> Int { role == "MAIN" ? 0 : role == "SUPPORTING" ? 1 : 2 }
        for pass in 0...2 {
            for entry in entries {
                for character in entry where rank(character.role) == pass {
                    guard let actor = character.actor else { continue }
                    if characters[actor.id] == nil { order.append(actor) }
                    if !(characters[actor.id] ?? []).contains(character.name) {
                        characters[actor.id, default: []].append(character.name)
                    }
                }
            }
        }
        return order.prefix(limit).map { Credit(actor: $0, characters: characters[$0.id] ?? []) }
    }

    /// An English track, as Plex ("English") or Jellyfin ("eng") names it.
    static func isEnglish(_ track: AudioTrack) -> Bool {
        guard let language = track.language?.lowercased() else { return false }
        return language == "en" || language == "eng" || language.hasPrefix("english")
    }

    static func hasEnglishAudio(_ sources: [MediaSource]) -> Bool {
        sources.contains { $0.audioTracks.contains(where: isEnglish) }
    }

    /// Animation, as Plex's agents and Jellyfin tag it.
    static func isAnimation(_ genres: [String]) -> Bool {
        genres.contains { ["animation", "anime"].contains($0.lowercased()) }
    }

    /// The AniList entries a page is: a film by its TMDB id; a show, a
    /// season or an episode by its show's TMDB and TVDB ids, with the season
    /// for a season or episode page.
    static func title(item: MediaItem, detail: MediaItemDetail?, showDetail: MediaItemDetail?) -> AnimeIDMap.Title? {
        switch item.kind {
        case .movie:
            return detail?.externalIDs["tmdb"].flatMap(Int.init).map { .movie(tmdb: $0) }
        case .show, .season, .episode:
            let ids = (item.kind == .show ? detail : showDetail ?? detail)?.externalIDs ?? [:]
            let tmdb = ids["tmdb"].flatMap(Int.init), tvdb = ids["tvdb"].flatMap(Int.init)
            guard tmdb != nil || tvdb != nil else { return nil }
            return .show(tmdb: tmdb, tvdb: tvdb, season: item.kind == .show ? nil : item.seasonNumber)
        default:
            return nil
        }
    }
}

@MainActor
enum EnglishDubCastLoader {

    /// The row for a page, or empty when it has none to show.
    static func credits(item: MediaItem, detail: MediaItemDetail?,
                        showDetail: MediaItemDetail?) async -> [EnglishDubCast.Credit] {
        guard item.ref.isPlex, !item.isMetadataOnly,
              EnglishDubCast.isAnimation((showDetail ?? detail)?.genres ?? []),
              let title = EnglishDubCast.title(item: item, detail: detail, showDetail: showDetail),
              await anyCopyHasEnglishAudio(item: item, detail: detail, showDetail: showDetail)
        else { return [] }
        let entries = await AnimeIDMap.shared.entries(for: title)
        guard !entries.isEmpty else { return [] }
        // A long franchise has a dozen entries; the row needs the first few.
        let ids = Array(entries.map(\.anilist).prefix(12))
        let characters = await AniListClient.shared.characters(for: ids)
        return EnglishDubCast.combine(ids.compactMap { characters[$0] })
    }

    /// An English track on this page's copy, or on any copy the servers hold
    /// (the episode Play would start, for a show). The other servers answer
    /// through Ways to Watch's lookup; this waits for them, up to `timeout`.
    private static func anyCopyHasEnglishAudio(item: MediaItem, detail: MediaItemDetail?,
                                               showDetail: MediaItemDetail?,
                                               timeout: Duration = .seconds(20)) async -> Bool {
        let own = detail?.mediaSources ?? []
        let title = item.kind == .season || item.kind == .episode ? showDetail?.item : item
        let lookup = title.flatMap { WaysToWatchLookup.offersWaysToWatch($0) ? WaysToWatchLookup.lookup(for: $0) : nil }
        func found() -> Bool {
            var sources = own
            if let lookup {
                for copy in [lookup.own] + lookup.others {
                    sources += copy.detail?.mediaSources ?? []
                    sources += copy.playTargetDetail?.mediaSources ?? []
                }
            }
            return EnglishDubCast.hasEnglishAudio(sources)
        }
        if found() { return true }
        guard let lookup else { return false }
        let deadline = ContinuousClock.now + timeout
        // Copies land as their servers answer; each is checked as it does.
        while !lookup.isFinished, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            if found() { return true }
        }
        return found()
    }
}

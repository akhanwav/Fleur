// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EnglishDubCast.swift
//  Rivulet
//
//  The detail page's English Dub Cast row: an animated title's English voice
//  actors and their characters. Anime comes from AniList (`AniListClient`)
//  through Fribb's id map (`AnimeIDMap`); a season or an episode page lists
//  its own season's entry, a show page combines every entry, main
//  characters first, each actor once. Other non-English animation comes from
//  The Dubbing Database (`DubDatabaseClient`), matched strictly, then from the
//  title's English Wikipedia article (`WikipediaCastClient`), with photos and
//  links from TMDB by name (`DubActorMatcher`).
//
//  Shown only for animation that some copy on the servers can play in
//  English: an English audio track on any copy of a film or episode, or on
//  the episode Play would start for any copy of a show.
//

import Foundation

nonisolated enum EnglishDubCast {

    /// A character and its English voice, as a cast page lists it
    /// (The Dubbing Database, Wikipedia).
    struct Role: Codable, Equatable, Sendable {
        let character: String
        let actor: String
    }

    /// Every dub cast source is told who is asking, with a way to reach the
    /// app's makers (Wikimedia's user-agent policy asks for one; Cloudflare in
    /// front of AniList refuses generic clients).
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        return "Fleur/\(version) (Apple TV media player; https://github.com/akhanwav/Fleur)"
    }

    /// One actor in the row, with every character they voice in it.
    struct Credit: Equatable, Sendable {
        /// Unique in a row: the source and its id for the actor.
        let key: String
        let name: String
        let image: URL?
        let characters: [String]
    }

    /// Settings → Appearance → Show English Dub Cast (on unless turned off).
    /// Off, no source is asked at all.
    static let settingKey = "showEnglishDubCast"

    static var isEnabled: Bool { SettingsStore.bool(settingKey, default: true) }

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
        return order.prefix(limit).map {
            Credit(key: "anilist:\($0.id)", name: $0.name, image: $0.image, characters: characters[$0.id] ?? [])
        }
    }

    /// A cast page's roles in its order, each actor once with all their
    /// characters. Photos come later, from TMDB.
    static func credits(_ roles: [Role], limit: Int = limit) -> [Credit] {
        var order: [String] = []
        var characters: [String: [String]] = [:]
        for role in roles {
            if characters[role.actor] == nil { order.append(role.actor) }
            if !role.character.isEmpty, !(characters[role.actor] ?? []).contains(role.character) {
                characters[role.actor, default: []].append(role.character)
            }
        }
        return order.prefix(limit).map {
            Credit(key: "dubdb:\($0)", name: $0, image: nil, characters: characters[$0] ?? [])
        }
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

    /// The row for a page, or empty when it has none to show: AniList's
    /// cast for anime it has, else The Dubbing Database's.
    static func credits(item: MediaItem, detail: MediaItemDetail?,
                        showDetail: MediaItemDetail?) async -> [EnglishDubCast.Credit] {
        guard EnglishDubCast.isEnabled, item.ref.isPlex, !item.isMetadataOnly,
              EnglishDubCast.isAnimation((showDetail ?? detail)?.genres ?? []),
              let title = EnglishDubCast.title(item: item, detail: detail, showDetail: showDetail),
              await anyCopyHasEnglishAudio(item: item, detail: detail, showDetail: showDetail)
        else { return [] }
        let entries = await AnimeIDMap.shared.entries(for: title)
        if !entries.isEmpty {
            // A long franchise has a dozen entries; the row needs the first few.
            let ids = Array(entries.map(\.anilist).prefix(12))
            let characters = await AniListClient.shared.characters(for: ids)
            let credits = EnglishDubCast.combine(ids.compactMap { characters[$0] })
            if !credits.isEmpty { return credits }
        }
        return await castPageCredits(for: title)
    }

    /// A non-English original's English dub from The Dubbing Database, else
    /// from its Wikipedia article's cast table, with each actor's TMDB photo
    /// where the name matches one person.
    private static func castPageCredits(for title: AnimeIDMap.Title) async -> [EnglishDubCast.Credit] {
        let tmdb: (id: Int, isMovie: Bool)
        switch title {
        case .movie(let id): tmdb = (id, true)
        case .show(let id?, _, _): tmdb = (id, false)
        case .show(nil, _, _): return []
        }
        guard let original = await TMDBClient.shared.originalTitle(tmdbId: tmdb.id, isMovie: tmdb.isMovie),
              original.language != "en" else { return [] }
        var roles = await DubDatabaseClient.shared.englishCast(
            for: .init(tmdbId: tmdb.id, isMovie: tmdb.isMovie, original: original)) ?? []
        if roles.isEmpty {
            roles = await WikipediaCastClient.shared.englishCast(tmdbId: tmdb.id, isMovie: tmdb.isMovie) ?? []
        }
        guard !roles.isEmpty else { return [] }
        let credits = EnglishDubCast.credits(roles)
        let matches = await DubActorMatcher.matches(for: credits.map(\.name))
        return credits.map { credit in
            EnglishDubCast.Credit(key: credit.key, name: credit.name,
                                  image: matches[credit.name]?.profileURL, characters: credit.characters)
        }
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

/// A dub actor's TMDB person, by exact name with a role in animation
/// (`TMDBClient.voiceActor`): their photo for a Dubbing Database cast, and
/// the actor page link for every dub cast. Read once per name per session.
@MainActor
enum DubActorMatcher {
    private static var known: [String: TMDBVoiceActor?] = [:]
    private static var inFlight: [String: Task<TMDBVoiceActor?, Never>] = [:]

    static func match(_ name: String) async -> TMDBVoiceActor? {
        if let known = known[name] { return known }
        if let task = inFlight[name] { return await task.value }
        let task = Task { await TMDBClient.shared.voiceActor(name: name) }
        inFlight[name] = task
        let match = await task.value
        inFlight[name] = nil
        known[name] = .some(match)
        return match
    }

    /// Several names, four at a time.
    static func matches(for names: [String]) async -> [String: TMDBVoiceActor] {
        var result: [String: TMDBVoiceActor] = [:]
        var index = 0
        while index < names.count {
            let batch = names[index..<min(index + 4, names.count)]
            await withTaskGroup(of: (String, TMDBVoiceActor?).self) { group in
                for name in batch { group.addTask { (name, await match(name)) } }
                for await (name, match) in group { if let match { result[name] = match } }
            }
            index += 4
        }
        return result
    }
}

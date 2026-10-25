// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EpisodePicker.swift
//  Rivulet
//
//  Which episode does "Play" mean when the user presses it on a season or a
//  show? Shared by the carousel hero and the home hero so both agree.
//

import Foundation

enum EpisodePicker {

    /// The episode Play should start, given a season's episodes in server order.
    ///
    /// A season has no playable media of its own, so pressing Play on one has to
    /// resolve to an episode:
    ///
    /// 1. An episode already in progress (`viewOffset > 0` and unwatched) —
    ///    the user is midway through it, so resume rather than skip past.
    /// 2. Otherwise the first **unplayed** episode.
    /// 3. Otherwise (the whole season is watched) the first episode, so Play
    ///    restarts the season rather than doing nothing.
    ///
    /// Returns nil only when `episodes` is empty.
    static func firstUnplayed(in episodes: [MediaItem]) -> MediaItem? {
        let ordered = inPlaybackOrder(episodes)
        return ordered.first(where: { $0.userState.isInProgress })
            ?? ordered.first(where: { !$0.userState.isPlayed })
            ?? ordered.first
    }

    /// Where a whole show's Play goes when Plex has no On Deck episode for it
    /// (Plex drops a show from On Deck after a while unwatched), over its
    /// episodes in playback order:
    ///
    /// 1. one in progress, to resume it;
    /// 2. the first unplayed one after the last played, so a new episode of a
    ///    show you were caught up on is next (not an old one you skipped);
    /// 3. the first unplayed one;
    /// 4. the first, to start again.
    ///
    /// Indexes into the arrays, so the Plex-metadata callers share it.
    static func nextUpIndex(inProgress: [Bool], played: [Bool]) -> Int? {
        guard !played.isEmpty else { return nil }
        if let index = inProgress.firstIndex(of: true) { return index }
        if let last = played.lastIndex(of: true),
           let next = played[(last + 1)...].firstIndex(of: false) { return next }
        return played.firstIndex(of: false) ?? 0
    }

    static func nextUp(in episodes: [MediaItem]) -> MediaItem? {
        let ordered = inPlaybackOrder(episodes)
        return nextUpIndex(inProgress: ordered.map(\.userState.isInProgress),
                           played: ordered.map(\.userState.isPlayed)).map { ordered[$0] }
    }

    /// The episode a Play press on `item` should start. `nil` if it can't be
    /// resolved (no provider data), in which case the caller plays `item` as-is.
    ///
    ///  - movie / episode: plays itself (returned unchanged).
    ///  - show: its Plex OnDeck episode, else `nextUp` over every episode.
    ///  - season: that season's first unplayed episode.
    ///
    /// Shared by the carousel's Play button and its title, so the title can
    /// never disagree with what Play does.
    static func resolvePlayTarget(
        for item: MediaItem, provider: MediaProvider
    ) async -> MediaItem? {
        switch item.kind {
        case .movie, .episode:
            return item
        case .show:
            if let onDeck = try? await provider.fullDetail(for: item.ref).nextEpisode {
                return onDeck
            }
            if let episodes = try? await provider.allEpisodes(of: item.ref), let next = nextUp(in: episodes) {
                return next
            }
            guard let firstSeason = try? await provider.children(of: item.ref).first
            else { return nil }
            let episodes = (try? await provider.children(of: firstSeason.ref)) ?? []
            return firstUnplayed(in: episodes)
        case .season:
            let episodes = (try? await provider.children(of: item.ref)) ?? []
            return firstUnplayed(in: episodes)
        default:
            return nil
        }
    }

    /// The Play button's title for `target`, what Play will start, wherever it
    /// shows: the detail and episode pages, the Home hero, Continue Watching
    /// and each server's Ways to Watch row. An episode is always named.
    static func playTitle(for target: MediaItem) -> String {
        let isEpisode = target.kind == .episode
        return playTitle(
            resumes: target.isInProgress,
            watched: target.isWatched,
            season: isEpisode ? target.seasonNumber : nil,
            episode: isEpisode ? target.episodeNumber : nil,
            timeLeft: ResumeText.timeLeft(offsetSeconds: target.userState.viewOffset,
                                          runtimeSeconds: target.runtime))
    }

    /// The same title for a Plex item (the Home hero's slides).
    static func playTitle(for target: PlexMetadata) -> String {
        let isEpisode = target.type == "episode"
        let offset = TimeInterval(target.viewOffset ?? 0) / 1000
        let runtime = target.duration.map { TimeInterval($0) / 1000 }
        return playTitle(
            resumes: WatchProgressPolicy.hasResumePoint(offsetSeconds: offset, runtimeSeconds: runtime),
            watched: target.isWatched,
            season: isEpisode ? target.parentIndex : nil,
            episode: isEpisode ? target.index : nil,
            timeLeft: ResumeText.timeLeft(offsetSeconds: offset, runtimeSeconds: runtime))
    }

    /// Apple's wording, our rule: a resume point (`WatchProgressPolicy`) says
    /// Resume and outranks the watched flag; a watched target says Play Again;
    /// else Play. An episode is named, and a resume carries the time left:
    /// "Play S5 · E3", "Resume S5 · E3 · 12 min left", "Resume · 42 min left".
    static func playTitle(resumes: Bool, watched: Bool, season: Int? = nil, episode: Int? = nil,
                          timeLeft: String? = nil) -> String {
        let code = season.flatMap { s in episode.map { "S\(s) · E\($0)" } }
        if resumes {
            if let code { return (["Resume " + code] + [timeLeft].compactMap { $0 }).joined(separator: " · ") }
            return timeLeft.map { "Resume · " + $0 } ?? "Resume"
        }
        if watched { return "Play Again" }
        return code.map { "Play " + $0 } ?? "Play"
    }

    /// Sort by season then episode number when those are present, so a caller
    /// that hands us an unordered array still gets S01E01 before S01E02. Items
    /// missing a number keep their relative position at the end (Plex normally
    /// returns children already ordered; this is belt-and-braces).
    static func inPlaybackOrder(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.seasonNumber, lhs.element.episodeNumber)
            let r = (rhs.element.seasonNumber, rhs.element.episodeNumber)
            guard let ls = l.0, let le = l.1, let rs = r.0, let re = r.1 else {
                return lhs.offset < rhs.offset   // stable: preserve server order
            }
            return (ls, le) < (rs, re)
        }.map(\.element)
    }
}

extension MediaUserState {
    /// Started but not finished. Plex marks an episode played via `viewCount`,
    /// and keeps a resume position in `viewOffset` independently, so an item can
    /// legitimately be both played and have an offset (a rewatch in progress).
    /// "In progress" means the user has somewhere to resume TO and hasn't
    /// finished it, which is why this is the one place that adds `!isPlayed`:
    /// On Deck has to move past an episode the user has already finished.
    ///
    /// No runtime is available on this type, so this takes the position-only
    /// overload of `WatchProgressPolicy.hasResumePoint`.
    var isInProgress: Bool {
        WatchProgressPolicy.hasResumePoint(offsetSeconds: viewOffset) && !isPlayed
    }
}

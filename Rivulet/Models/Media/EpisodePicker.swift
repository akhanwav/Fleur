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

    /// The episode a Play press on `item` should start. `nil` if it can't be
    /// resolved (no provider data), in which case the caller plays `item` as-is.
    ///
    ///  - movie / episode: plays itself (returned unchanged).
    ///  - show: its Plex OnDeck episode; if nothing's started, the first
    ///    season's first unplayed episode.
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

    /// The Play button's title for `target` (what Play starts) on a page of
    /// kind `page`. A show or season page names the episode; an item's own
    /// page does not.
    static func playTitle(for target: MediaItem, on page: MediaKind) -> String {
        let onParent = (page == .show || page == .season) && target.kind == .episode
        let first = target.episodeNumber == 1 && (page == .season || target.seasonNumber == 1)
        return playTitle(
            resumes: target.isInProgress,
            watched: target.isWatched,
            season: onParent ? target.seasonNumber : nil,
            episode: onParent ? target.episodeNumber : nil,
            isFirstEpisode: onParent && first)
    }

    /// Apple's wording, our rule: a resume point (`WatchProgressPolicy`) says
    /// Resume and outranks the watched flag; a watched target says Play Again;
    /// an untouched first episode says Play First Episode; else Play.
    static func playTitle(
        resumes: Bool, watched: Bool, season: Int? = nil, episode: Int? = nil, isFirstEpisode: Bool = false
    ) -> String {
        let code = season.flatMap { s in episode.map { " S\(s), E\($0)" } } ?? ""
        if resumes { return "Resume" + code }
        if watched { return "Play Again" }
        if isFirstEpisode { return "Play First Episode" }
        return "Play" + code
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

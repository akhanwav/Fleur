//
//  CopyEpisodes.swift
//  Rivulet
//
//  A show page switched to another copy (Ways to Watch, On Your Servers) lists
//  that copy's episodes: its server, its library, its watch states and resume
//  points, so an episode plays from it. An episode the page's own copy has and
//  the selected one lacks stays in the list, greyed, as "Not on <server>".
//

import Foundation

nonisolated enum CopyEpisodes {

    struct Merged: Equatable {
        let seasons: [MediaItem]
        let episodes: [MediaItem]
        /// The page's own episodes the selected copy lacks (`ref.itemID`).
        let missing: Set<String>
    }

    /// The selected copy's seasons and episodes, plus the original's that it
    /// lacks, matched by season and episode number. A missing episode moves
    /// under the copy's season of the same number, when it has one, so the
    /// rail keeps one divider and one pill per season. Episodes sort by season
    /// then number, as Plex lists them; unnumbered ones keep their order last.
    static func merge(copy: [MediaItem], copySeasons: [MediaItem],
                      original: [MediaItem], originalSeasons: [MediaItem]) -> Merged {
        func key(_ episode: MediaItem) -> String? {
            guard let season = episode.seasonNumber, let number = episode.episodeNumber else { return nil }
            return "\(season):\(number)"
        }
        let copyKeys = Set(copy.compactMap(key))
        let copyIDs = Set(copy.map(\.ref.itemID))
        let seasonByNumber = Dictionary(copySeasons.compactMap { season in season.seasonNumber.map { ($0, season.ref) } },
                                        uniquingKeysWith: { first, _ in first })
        var missing: Set<String> = []
        var episodes = copy
        for episode in original {
            // An episode with no number cannot be matched, and an id the copy
            // already uses would collide in the rail: neither is listed.
            guard let key = key(episode), !copyKeys.contains(key), !copyIDs.contains(episode.ref.itemID) else { continue }
            let season = episode.seasonNumber.flatMap { seasonByNumber[$0] }
            episodes.append(season.map { episode.withParentRef($0) } ?? episode)
            missing.insert(episode.ref.itemID)
        }
        let ordered = episodes.enumerated().sorted { a, b in
            switch (a.element.seasonNumber, b.element.seasonNumber) {
            case let (sa?, sb?) where sa != sb: return sa < sb
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            switch (a.element.episodeNumber, b.element.episodeNumber) {
            case let (ea?, eb?) where ea != eb: return ea < eb
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)

        let copyNumbers = Set(copySeasons.compactMap(\.seasonNumber))
        let extraSeasons = originalSeasons.filter { season in
            guard let number = season.seasonNumber else { return false }
            return !copyNumbers.contains(number) && missing.contains { id in
                ordered.first { $0.ref.itemID == id }?.seasonNumber == number
            }
        }
        let seasons = (copySeasons + extraSeasons).sorted { ($0.seasonNumber ?? .max) < ($1.seasonNumber ?? .max) }
        return Merged(seasons: seasons, episodes: ordered, missing: missing)
    }
}

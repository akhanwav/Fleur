// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MovieCuts.swift
//  Rivulet
//
//  A movie whose copies are different cuts (theatrical, extended, director's,
//  final): copies with different edition titles, or files whose lengths differ
//  by more than five minutes. Only then is the cut named beside its quality.
//  The runtime is every owned movie's selected file (`runtime(of:)`), cuts or
//  not; TMDB's is left for titles on no server.
//
//  Plex names a cut with the item's `editionTitle`, and servers word one cut
//  differently ("Extended", "Extended Cut"), so titles compare by `cutKey`.
//  A copy without one is named by the titled copies of the same length when
//  they agree, else by its runtime ("4h 23m"); with exactly two lengths and no
//  titles anywhere, the longer is the Extended Cut. Measured on Alpha and a
//  shared server: Blade Runner's cuts are all 117 minutes (titles only), The
//  Lord of the Rings' theatrical and extended differ by 50 to 60.
//

import Foundation

nonisolated enum MovieCuts {
    /// One file of the movie: its copy's edition title and its own length.
    struct Version: Equatable, Sendable {
        let id: String
        let edition: String?
        let duration: TimeInterval
    }

    /// Lengths closer than this are the same cut (servers' encodes differ
    /// by seconds, cuts by many minutes).
    static let tolerance: TimeInterval = 5 * 60

    static func isMultiCut(_ versions: [Version]) -> Bool {
        // An untitled copy is not a different title: it may be any cut.
        let editions = Set(versions.compactMap { edition($0.edition).map(cutKey) })
        if editions.count > 1 { return true }
        let durations = versions.map(\.duration).filter { $0 > 0 }
        guard let shortest = durations.min(), let longest = durations.max() else { return false }
        return longest - shortest > tolerance
    }

    /// The cut's name: its edition title, a titled copy's of the same length,
    /// or "Extended Cut" for the longer of exactly two untitled lengths. nil
    /// when the movie has one cut, or this one has no name.
    static func name(of version: Version, among versions: [Version]) -> String? {
        guard isMultiCut(versions) else { return nil }
        if let own = edition(version.edition) { return own }
        let titled = versions.filter { abs($0.duration - version.duration) <= tolerance }
            .compactMap { edition($0.edition) }
        if Set(titled.map(cutKey)).count == 1 { return commonest(titled) }
        guard versions.allSatisfy({ edition($0.edition) == nil }) else { return nil }
        let lengths = clusters(versions.map(\.duration).filter { $0 > 0 })
        guard lengths.count == 2, let longer = lengths.last,
              longer.contains(where: { abs($0 - version.duration) <= tolerance }) else { return nil }
        return "Extended Cut"
    }

    /// What a Ways to Watch row says after the quality: the cut's name, else
    /// its runtime. nil for a movie with one cut.
    static func label(of version: Version, among versions: [Version]) -> String? {
        guard isMultiCut(versions) else { return nil }
        let runtime = version.duration > 0 ? formatRuntime(version.duration) : nil
        guard let name = name(of: version, among: versions) else { return runtime }
        // An edition title is the cut's own name; an inferred one carries the
        // length that made it.
        return edition(version.edition) == nil ? [name, runtime].compactMap { $0 }.joined(separator: " · ") : name
    }

    /// The selected file's own length, for any movie on the servers; nil
    /// (no file read yet, or a title on none) keeps the metadata runtime.
    static func runtime(of version: Version?) -> TimeInterval? {
        guard let version, version.duration > 0 else { return nil }
        return version.duration
    }

    /// "4h 23m", "58m": whole minutes, as the detail page's info line reads.
    static func formatRuntime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// One cut under its servers' names: "Extended", "Extended Cut" and
    /// "Extended Edition" are one; "Extended Fan Cut" is another.
    static func cutKey(_ title: String) -> String {
        let filler: Set<String> = ["the", "cut", "edition", "version"]
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let kept = words.filter { !filler.contains($0) }
        return (kept.isEmpty ? words : kept).joined(separator: " ")
    }

    /// The name most copies use, the fuller one on a tie.
    private static func commonest(_ titles: [String]) -> String? {
        let counts = Dictionary(titles.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $0.key.count) < ($1.value, $1.key.count) }?.key
    }

    private static func edition(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    /// Lengths grouped where neighbours sit within the tolerance, shortest first.
    private static func clusters(_ durations: [TimeInterval]) -> [[TimeInterval]] {
        var groups: [[TimeInterval]] = []
        for duration in durations.sorted() {
            if let last = groups.last?.last, duration - last <= tolerance {
                groups[groups.count - 1].append(duration)
            } else {
                groups.append([duration])
            }
        }
        return groups
    }
}

extension MovieCuts.Version {
    /// A file of a movie copy, named by its copy's edition.
    init(copyID: String, edition: String?, source: MediaSource) {
        self.init(id: "\(copyID)/\(source.id)", edition: edition, duration: source.duration)
    }
}

extension MediaItem {
    /// The same item with another runtime: a multi-cut movie's selected file.
    func withRuntime(_ seconds: TimeInterval?) -> MediaItem {
        guard let seconds, seconds != runtime else { return self }
        return MediaItem(
            ref: ref, kind: kind, title: title, sortTitle: sortTitle, overview: overview, year: year,
            releaseDate: releaseDate, contentRating: contentRating, runtime: seconds, isMusic: isMusic,
            parentRef: parentRef, grandparentRef: grandparentRef, seriesTitle: seriesTitle,
            episodeNumber: episodeNumber, seasonNumber: seasonNumber, childProgress: childProgress,
            userState: userState, artwork: artwork, parentArtwork: parentArtwork,
            grandparentArtwork: grandparentArtwork, versionCount: versionCount, editionTitle: editionTitle,
            addedAt: addedAt)
    }
}

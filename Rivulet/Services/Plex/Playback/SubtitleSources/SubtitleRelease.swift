//
//  SubtitleRelease.swift
//  Rivulet
//
//  Reads a release name ("Chainsaw.Man.S01E01.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG",
//  "[SubsPlease] Chainsaw Man - 01 (1080p) [A1B2C3].mkv") into its parts, and
//  scores a subtitle's release against the file's, after Bazarr: an exact file
//  hash is 100%, the wrong episode 0%, and between them the release group and
//  source weigh most, since a subtitle's timing follows the exact release.
//

import Foundation

nonisolated struct ReleaseInfo: Equatable, Sendable {
    var season: Int?
    var episode: Int?
    /// A whole season ("S01", "Season 1"), no episode named.
    var isSeasonPack = false
    /// "WEB-DL", "WEBRip", "WEB", "BluRay", "Remux", "HDTV", "DVD".
    var source: String?
    var group: String?
    /// "2160p", "1080p", …
    var resolution: String?
    /// "H.264", "H.265", "AV1", "XviD".
    var codec: String?
    /// "AMZN", "NF", "DSNP", "HMAX", "ATVP", "CR", …
    var service: String?
    /// "Extended", "Director's Cut", …
    var edition: String?
    var frameRate: Double?
    var isHearingImpaired = false
    var isForced = false
    var isSignsAndSongs = false
    var isDubtitle = false

    /// The family a source belongs to, which is what timing follows: every
    /// web variant is one encode of the stream, a remux is the disc.
    var sourceFamily: String? {
        switch source {
        case "WEB-DL", "WEBRip", "WEB": "web"
        case "BluRay", "Remux": "bluray"
        case let other: other?.lowercased()
        }
    }

    /// "SubsPlease · WEB · 1080p": the group, the source, the resolution.
    var cleanName: String? {
        let parts = [group, [service, source].compactMap { $0 }.joined(separator: " ").nilIfEmpty, resolution]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

nonisolated enum ReleaseParser {
    static func parse(_ raw: String) -> ReleaseInfo {
        var info = ReleaseInfo()
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".mkv", ".mp4", ".m4v", ".avi", ".ts", ".srt", ".ass", ".ssa", ".vtt", ".sub", ".zip"]
        where name.lowercased().hasSuffix(ext) {
            name.removeLast(ext.count)
        }
        let lower = name.lowercased()
        let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let wordSet = Set(words)

        // Season and episode.
        if let m = lower.firstMatch(of: #/s(\d{1,2})[ ._-]?e(\d{1,4})/#) {
            info.season = Int(m.1); info.episode = Int(m.2)
        } else if let m = lower.firstMatch(of: #/(?:^|[^\d])(\d{1,2})x(\d{2,3})(?:[^\d]|$)/#) {
            info.season = Int(m.1); info.episode = Int(m.2)
        } else if lower.firstMatch(of: #/(?:^|[^a-z])ep?[ ._]?\d{1,3}[ ._]?-[ ._]?(?:ep?)?\d{1,3}(?:[^\dp]|$)/#) != nil {
            // "Ep 1-12", "E01-12": every episode of the season in one entry.
            info.isSeasonPack = true
            if let m = lower.firstMatch(of: #/s(\d{1,2})(?:[^\d]|$)/#) { info.season = Int(m.1) }
        } else if let m = lower.firstMatch(of: #/(?:^|[^a-z])(?:ep|episode)[ ._]?(\d{1,3})(?:[^\d]|$)/#) {
            info.episode = Int(m.1)
            if let s = lower.firstMatch(of: #/(?:^|[^a-z])s(\d{1,2})(?:[^\d]|$)/#) { info.season = Int(s.1) }
        } else if let m = lower.firstMatch(of: #/(?:^|[ ._\[(-])s(\d{1,2})(?:[ ._\])-]|$)/#) {
            info.season = Int(m.1); info.isSeasonPack = true
        } else if let m = lower.firstMatch(of: #/season[ ._-]?(\d{1,2})/#) {
            info.season = Int(m.1)
            info.isSeasonPack = lower.firstMatch(of: #/episode[ ._-]?\d/#) == nil
        } else if let m = lower.firstMatch(of: #/\s-\s(\d{1,4})(?:v\d)?(?:[\s\[(.]|$)/#) {
            // Anime: "[Group] Title - 01 (1080p)", numbered across seasons.
            info.episode = Int(m.1)
        }
        if info.season != nil, info.episode == nil, wordSet.contains("complete") { info.isSeasonPack = true }

        // Source.
        if wordSet.contains("remux") { info.source = "Remux" }
        else if lower.contains("web-dl") || lower.contains("webdl") || lower.contains("web.dl") { info.source = "WEB-DL" }
        else if wordSet.contains("webrip") || lower.contains("web-rip") { info.source = "WEBRip" }
        else if wordSet.contains("web") { info.source = "WEB" }
        else if !wordSet.isDisjoint(with: ["bluray", "bdrip", "brrip", "bdremux", "bd", "bdmv"]) || lower.contains("blu-ray") {
            info.source = "BluRay"
        }
        else if wordSet.contains("hdtv") { info.source = "HDTV" }
        else if !wordSet.isDisjoint(with: ["dvdrip", "dvd", "dvd5", "dvd9"]) { info.source = "DVD" }

        // Resolution.
        if let m = lower.firstMatch(of: #/(?:^|[^\d])(2160|1080|720|576|480)[pi](?:[^a-z]|$)/#) {
            info.resolution = "\(m.1)p"
        } else if !wordSet.isDisjoint(with: ["4k", "uhd"]) {
            info.resolution = "2160p"
        }

        // Codec.
        if lower.contains("x265") || lower.contains("h265") || lower.contains("h.265") || wordSet.contains("hevc") {
            info.codec = "H.265"
        } else if lower.contains("x264") || lower.contains("h264") || lower.contains("h.264") || wordSet.contains("avc") {
            info.codec = "H.264"
        } else if wordSet.contains("av1") {
            info.codec = "AV1"
        } else if wordSet.contains("xvid") || wordSet.contains("divx") {
            info.codec = "XviD"
        }

        // Streaming service.
        let services: [(String, String)] = [
            ("amzn", "AMZN"), ("amazon", "AMZN"), ("nf", "NF"), ("netflix", "NF"), ("dsnp", "DSNP"),
            ("disney", "DSNP"), ("hmax", "HMAX"), ("max", "MAX"), ("atvp", "ATVP"), ("hulu", "HULU"),
            ("pcok", "PCOK"), ("pmtp", "PMTP"), ("cr", "CR"), ("crunchyroll", "CR"), ("funi", "FUNI"),
            ("funimation", "FUNI"), ("hidive", "HIDIVE"), ("adn", "ADN"), ("itunes", "iT"), ("it", "iT"),
            ("stan", "STAN"), ("hbo", "HBO"), ("hbogo", "HBO"), ("sho", "SHO"), ("bcore", "BCORE"),
        ]
        // Two-letter codes ("NF", "CR", "iT") only beside a source, where they can't be words.
        let short: Set<String> = ["nf", "cr", "it", "max", "hbo", "sho", "stan", "adn"]
        for (index, word) in words.enumerated() {
            guard let service = services.first(where: { $0.0 == word })?.1 else { continue }
            if short.contains(word) {
                let near = words[max(0, index - 2)..<min(words.count, index + 3)]
                guard near.contains(where: { ["web", "webrip", "webdl", "dl", "1080p", "720p", "2160p"].contains($0) })
                else { continue }
            }
            info.service = service
            break
        }

        // Edition.
        let editions: [(String, String)] = [
            ("director's cut", "Director's Cut"), ("directors cut", "Director's Cut"), ("directors.cut", "Director's Cut"),
            ("extended", "Extended"), ("uncut", "Uncut"), ("unrated", "Unrated"), ("remastered", "Remastered"),
            ("imax", "IMAX"), ("theatrical", "Theatrical"), ("criterion", "Criterion"), ("final cut", "Final Cut"),
            ("final.cut", "Final Cut"),
        ]
        info.edition = editions.first { lower.contains($0.0) }?.1

        // Frame rate.
        if let m = lower.firstMatch(of: #/(\d{2}(?:\.\d{1,3})?)\s?fps/#) {
            info.frameRate = Double(m.1)
        } else if let m = lower.firstMatch(of: #/(?:^|[^\d])(23\.976|29\.97|59\.94|23976)(?:[^\d]|$)/#) {
            info.frameRate = m.1 == "23976" ? 23.976 : Double(m.1)
        }

        // Kind.
        // "SDH", "HI", "CC", "[HI]", "Hearing.Impaired", "hearing-impaired", "eng.hi.srt".
        info.isHearingImpaired = !wordSet.isDisjoint(with: ["sdh", "hi", "cc", "hoh"])
            || lower.replacingOccurrences(of: "[._-]", with: " ", options: .regularExpression).contains("hearing impaired")
        info.isForced = wordSet.contains("forced") || lower.contains("foreign parts")
        info.isSignsAndSongs = lower.contains("signs") || lower.contains("s&s") || lower.contains("songs")
        info.isDubtitle = lower.contains("dubtitle") || lower.contains("dub-matched") || lower.contains("dubmatched")
            || lower.contains("dub matched") || lower.contains("closed caption dub")

        // A leading "[CR]" names the service, not a group.
        if let bracket = leadingBracket(name), let service = services.first(where: { $0.0 == bracket.lowercased() })?.1 {
            info.service = info.service ?? service
        } else {
            info.group = group(name)
        }
        return info
    }

    private static let notGroups: Set<String> = [
        "dl", "rip", "hd", "web", "x264", "x265", "h264", "h265", "hevc", "avc", "aac", "ac3", "dts", "ma",
        "subs", "sub", "eng", "en", "english", "sdh", "hi", "forced", "remux", "bluray", "webrip", "hdr",
    ]

    /// The release group: "[Group] …" at the start (anime), else the token
    /// after the last "-" when it is a single word ("…x264-AMIABLE").
    static func leadingBracket(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let inside = trimmed[trimmed.index(after: trimmed.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        return inside.isEmpty || inside.count > 24 ? nil : inside
    }

    static func group(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let leading = leadingBracket(name) { return leading }
        if let dashed = dashGroup(trimmed) { return dashed }
        // "….[SubsPlease]": a trailing bracket holding one word, not a CRC or a tag.
        for m in trimmed.matches(of: #/\[([A-Za-z][A-Za-z0-9_-]{1,19})\]/#).reversed() {
            let word = String(m.1)
            let isCRC = word.count == 8 && word.allSatisfy(\.isHexDigit)
            if !isCRC, !notGroups.contains(word.lowercased()), word.firstMatch(of: #/^\d{3,4}p$/#) == nil {
                return word
            }
        }
        return nil
    }

    private static func dashGroup(_ trimmed: String) -> String? {
        var tail = trimmed
        // A trailing tag ("[rarbg]", "(1)") is not the group.
        while let last = tail.last, last == "]" || last == ")",
              let open = tail.lastIndex(of: last == "]" ? "[" : "("), open != tail.startIndex {
            tail = String(tail[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard let dash = tail.lastIndex(of: "-") else { return nil }
        let candidate = String(tail[tail.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        // Dots only as an acronym's ("E.N.D").
        let acronym = candidate.wholeMatch(of: #/[A-Za-z](\.[A-Za-z])+\.?/#) != nil
        guard !candidate.isEmpty, candidate.count <= 20,
              acronym || candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "@" }),
              !notGroups.contains(candidate.lowercased()),
              candidate.contains(where: \.isLetter) else { return nil }
        return candidate
    }
}

/// How a subtitle relates to the file it would play over.
nonisolated enum SubtitleMatchKind: Int, Sendable, Comparable {
    case title, release, exactFile

    var label: String {
        switch self {
        case .exactFile: "Exact file"
        case .release: "Release"
        case .title: "Title"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

nonisolated enum SubtitleMatch {
    /// Points out of 100 for a release that is otherwise right: the right
    /// title (and episode) is the floor, the group and source carry the
    /// release, resolution and codec barely move it.
    static let weights: [(part: String, weight: Double)] = [
        ("title", 30), ("group", 30), ("source", 18), ("service", 7), ("edition", 5),
        ("frameRate", 5), ("resolution", 3), ("codec", 2),
    ]

    /// The file's facts a subtitle is scored against.
    struct FileFacts: Sendable {
        var release: ReleaseInfo
        var frameRate: Double?
        var season: Int?
        var episode: Int?
        var isEpisode: Bool
    }

    /// Whether a subtitle's own season and episode (from the source, else its
    /// name) rule it out for the file: another episode, another season. A
    /// season pack of the right season contains it.
    static func isOtherEpisode(_ sub: ReleaseInfo, season: Int?, episode: Int?, file: FileFacts) -> Bool {
        guard file.isEpisode else { return false }
        let subSeason = season ?? sub.season, subEpisode = episode ?? sub.episode
        if let subSeason, let fileSeason = file.season, subSeason != fileSeason { return true }
        if sub.isSeasonPack, episode == nil { return false }
        if let subEpisode, let fileEpisode = file.episode, subEpisode != fileEpisode { return true }
        return false
    }

    /// 0–100. An exact file hash is 100; another episode 0; otherwise the
    /// weighted parts the subtitle shares with the file, capped at 99. A part
    /// neither name gives (no group on a renamed file) still counts against
    /// the total, as in Bazarr: nothing shows the subtitle fits that release.
    /// Two parts are left out instead: the frame rate unless both sides give
    /// one, and the service unless the file is a web release.
    static func percent(_ sub: ReleaseInfo, frameRate subRate: Double?, season: Int?, episode: Int?,
                        isHashMatch: Bool, file: FileFacts) -> Int {
        if isHashMatch { return 100 }
        if isOtherEpisode(sub, season: season, episode: episode, file: file) { return 0 }
        let f = file.release
        var earned = 0.0, possible = 0.0
        func part(_ name: String, applies: Bool = true, _ matches: Bool) {
            guard applies, let weight = weights.first(where: { $0.part == name })?.weight else { return }
            possible += weight
            if matches { earned += weight }
        }
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        part("title", true)
        part("group", same(sub.group, f.group))
        part("source", same(sub.sourceFamily, f.sourceFamily))
        part("service", applies: f.sourceFamily == "web", sub.service == f.service)
        part("edition", sub.edition == f.edition)
        let rate = subRate ?? sub.frameRate
        part("frameRate", applies: rate != nil && file.frameRate != nil,
             abs((rate ?? 0) - (file.frameRate ?? 0)) < 0.05)
        part("resolution", same(sub.resolution, f.resolution))
        part("codec", same(sub.codec, f.codec))
        return min(99, Int((earned / possible * 100).rounded()))
    }

    static func kind(_ sub: ReleaseInfo, isHashMatch: Bool, file: FileFacts) -> SubtitleMatchKind {
        if isHashMatch { return .exactFile }
        let f = file.release
        guard let group = sub.group, group.lowercased() == f.group?.lowercased() else { return .title }
        // The same group's other source (its BluRay of a web file) is not this release.
        if let a = sub.sourceFamily, let b = f.sourceFamily, a != b { return .title }
        return .release
    }
}

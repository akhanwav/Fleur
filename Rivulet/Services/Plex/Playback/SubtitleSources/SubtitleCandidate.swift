//
//  SubtitleCandidate.swift
//  Rivulet
//
//  One row of the combined subtitle search: Plex's own search, OpenSubtitles
//  and SubSource, ranked together (`SubtitleRanking`).
//

import Foundation

/// Where a subtitle came from, as its row names it.
nonisolated enum SubtitleOrigin: String, Codable, Sendable, Hashable {
    case embedded
    case externalFile
    case plexSearch
    case openSubtitles
    case subSource

    var label: String {
        switch self {
        case .embedded: "Embedded"
        case .externalFile: "External file"
        case .plexSearch: "Plex search"
        case .openSubtitles: "OpenSubtitles"
        case .subSource: "SubSource"
        }
    }

    /// Fetched by a search, not shipped with the file.
    var isDownloaded: Bool { self == .plexSearch || self == .openSubtitles || self == .subSource }

    /// A Plex stream's origin. Plex's search downloads carry the provider's id
    /// (`sourceKey`); a file stored on the Apple TV has a file URL for a key
    /// (`LocalSubtitleStore`).
    init(_ stream: PlexStream) {
        guard let key = stream.key else { self = .embedded; return }
        if key.hasPrefix("file:") {
            self = stream.providerTitle == SubtitleOrigin.subSource.label ? .subSource : .openSubtitles
        } else if stream.sourceKey != nil || stream.providerTitle != nil {
            self = .plexSearch
        } else {
            self = .externalFile
        }
    }
}

nonisolated struct SubtitleCandidate: Identifiable, Sendable {
    enum Payload: Sendable {
        case plex(PlexStream)
        case openSubtitles(fileID: Int)
        case subSource(subtitleID: String)
    }

    let id: String
    let origin: SubtitleOrigin
    let release: String
    /// ISO 639-1 where the source says so ("en").
    let language: String?
    let isHearingImpaired: Bool
    let isForced: Bool
    let downloads: Int?
    /// Out of 10.
    let rating: Double?
    /// The source matched the file's OpenSubtitles hash: made for this exact release.
    let isHashMatch: Bool
    let payload: Payload
    /// "srt", "ass", where the source says (OpenSubtitles sends SRT).
    var format: String? = nil
    /// The source's own season and episode, else the release name's.
    var season: Int? = nil
    var episode: Int? = nil
    /// The source's frame rate, where it gives one (OpenSubtitles' `fps`).
    var frameRate: Double? = nil
    /// Set by `SubtitleSearch.search` against the file (`SubtitleMatch`).
    var matchPercent: Int = 0
    var matchKind: SubtitleMatchKind = .title
    /// The source marks it dub-matched (SubSource's commentary).
    var isDubtitle = false

    var info: ReleaseInfo { ReleaseParser.parse(release) }

    /// The Type column: the source's flags, then what the release name says.
    var kind: SubtitleKind {
        let info = info
        if isForced || info.isForced { return .forced }
        if info.isSignsAndSongs { return .signsAndSongs }
        if isDubtitle || info.isDubtitle { return .dubtitle }
        if isHearingImpaired || info.isHearingImpaired { return .sdh }
        return .full
    }
}

nonisolated enum SubtitleKind: Int, CaseIterable, Sendable {
    case full, sdh, forced, signsAndSongs, dubtitle

    /// Anime names its plain subtitles "Subtitles", beside "Dubtitles"
    /// (subtitles matched to the English dub).
    func label(isAnime: Bool) -> String {
        switch self {
        case .full: isAnime ? "Subtitles" : "Full"
        case .sdh: "SDH"
        case .forced: "Forced"
        case .signsAndSongs: "Signs & Songs"
        case .dubtitle: "Dubtitles"
        }
    }
}

/// The table's sort orders. Match % is the default; each falls through to
/// the others, then the sources' own order.
nonisolated enum SubtitleSort: Sendable, CaseIterable {
    case percent, match, downloads, rating

    static func sorted(_ candidates: [SubtitleCandidate], by sort: SubtitleSort = .percent) -> [SubtitleCandidate] {
        func keys(_ c: SubtitleCandidate) -> [Double] {
            let percent = Double(c.matchPercent), kind = Double(c.matchKind.rawValue)
            let downloads = Double(c.downloads ?? -1), rating = c.rating ?? -1
            switch sort {
            case .percent: return [percent, kind, downloads, rating]
            case .match: return [kind, percent, downloads, rating]
            case .downloads: return [downloads, percent, rating]
            case .rating: return [rating, percent, downloads]
            }
        }
        return candidates.enumerated().sorted { a, b in
            let x = keys(a.element), y = keys(b.element)
            return x != y ? x.lexicographicallyPrecedes(y, by: >) : a.offset < b.offset
        }.map(\.element)
    }
}

/// How alike a release name is to the file's, used to pick which of a
/// SubSource entry's release names to show.
nonisolated enum SubtitleRanking {
    /// How much of a release name agrees with the file's, in steps of 0.1 so
    /// near-equal names fall through to downloads: shared tokens over all of
    /// them, plus the release group (the token after the last "-") when it is
    /// the file's.
    static func releaseScore(_ release: String, fileName: String) -> Double {
        let releaseTokens = tokens(release), fileTokens = tokens(fileName)
        guard !releaseTokens.isEmpty, !fileTokens.isEmpty else { return 0 }
        let a = Set(releaseTokens), b = Set(fileTokens)
        var score = Double(a.intersection(b).count) / Double(a.union(b).count)
        if let group = releaseGroup(release), group == releaseGroup(fileName) { score += 0.3 }
        return (score * 10).rounded() / 10
    }

    /// "x264-AMIABLE.mkv" → "amiable".
    private static func releaseGroup(_ name: String) -> String? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        return tokens(String(name[name.index(after: dash)...])).first
    }

    /// Lower-cased words and numbers; the file's extension dropped.
    static func tokens(_ name: String) -> [String] {
        var name = name.lowercased()
        for ext in [".mkv", ".mp4", ".m4v", ".avi", ".ts", ".srt", ".ass", ".vtt"] where name.hasSuffix(ext) {
            name.removeLast(ext.count)
        }
        return name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// What went wrong at a subtitle source, said plainly.
nonisolated enum SubtitleSourceError: Error, Sendable, Equatable {
    case signInFailed
    case badKey
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded(resets: String?)
    case server(Int)
    case noFile

    func message(_ origin: SubtitleOrigin) -> String {
        let name = origin.label
        switch self {
        case .signInFailed: return "\(name) sign-in failed. Check the username and password."
        case .badKey: return "\(name) refused the API key."
        case .rateLimited(let after):
            guard let after, after > 0 else { return "\(name) is busy. Try again in a minute." }
            let minutes = Int((after / 60).rounded(.up))
            return minutes <= 1 ? "\(name) is busy. Try again in a minute."
                : "\(name) is busy. Try again in \(minutes) minutes."
        case .quotaExceeded(let resets):
            return resets.map { "\(name) daily download limit reached. It resets in \($0)." }
                ?? "\(name) daily download limit reached."
        case .server(let code): return "\(name) isn't responding (\(code))."
        case .noFile: return "\(name) sent no subtitle file."
        }
    }
}

/// How a subtitle row reads, in the detail page's picker and the player's
/// menu alike: the language and format first ("English SDH · SRT · Forced"),
/// then where it came from, "Downloaded" for a search's file, and the release
/// or file name ("OpenSubtitles · Downloaded · Shivers.1975.720p.BluRay").
enum SubtitleLabels {
    static func title(language: String?, codec: String?, isHearingImpaired: Bool, isForced: Bool) -> String {
        var name = TrackLabels.languageName(language) ?? "Unknown"
        if isHearingImpaired { name += " SDH" }
        var parts = [name]
        if let codec, !codec.isEmpty { parts.append(TrackLabels.subtitleFormat(codec)) }
        if isForced { parts.append("Forced") }
        return parts.joined(separator: " · ")
    }

    static func detail(origin: SubtitleOrigin?, isExternal: Bool, release: String?) -> String {
        let origin = origin ?? (isExternal ? .externalFile : .embedded)
        var parts = [origin.label]
        if origin.isDownloaded { parts.append("Downloaded") }
        if let release = release?.trimmingCharacters(in: .whitespaces), !release.isEmpty { parts.append(release) }
        return parts.joined(separator: " · ")
    }

    static func title(_ track: MediaTrack) -> String {
        title(language: track.languageCode ?? track.language, codec: track.codec,
              isHearingImpaired: track.isHearingImpaired, isForced: track.isForced)
    }

    static func detail(_ track: MediaTrack) -> String {
        detail(origin: track.origin, isExternal: track.isExternal || track.subtitleKey != nil, release: track.releaseName)
    }

    static func title(_ track: SubtitleTrack) -> String {
        title(language: track.language, codec: track.codec,
              isHearingImpaired: track.isHearingImpaired, isForced: track.isForced)
    }

    static func detail(_ track: SubtitleTrack) -> String {
        detail(origin: track.origin, isExternal: !track.isEmbedded, release: track.releaseName)
    }

    /// The release a search's file was made for, or a track's own title when
    /// it says more than its language ("Signs & Songs", not "English").
    nonisolated static func releaseName(of stream: PlexStream) -> String? {
        guard let title = stream.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        let codeName = stream.languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
        let plain = [stream.language, stream.displayTitle, codeName].compactMap { $0?.lowercased() }
        return plain.contains(title.lowercased()) ? nil : title
    }

    /// A search result's row: the release, then the source, the counts, the
    /// flags and "Exact match".
    static func resultTitle(_ candidate: SubtitleCandidate) -> String {
        candidate.release.isEmpty ? (TrackLabels.languageName(candidate.language) ?? "Subtitles") : candidate.release
    }

    static func resultDetail(_ candidate: SubtitleCandidate) -> String {
        var parts = [candidate.origin.label]
        if candidate.isHashMatch { parts.append("Exact match") }
        if let downloads = candidate.downloads {
            parts.append(downloads.formatted(.number) + (downloads == 1 ? " download" : " downloads"))
        }
        if let rating = candidate.rating, rating > 0 { parts.append("★ " + rating.formatted(.number.precision(.fractionLength(1)))) }
        if let language = TrackLabels.languageName(candidate.language) { parts.append(language) }
        if candidate.isHearingImpaired { parts.append("SDH") }
        if candidate.isForced { parts.append("Forced") }
        return parts.joined(separator: " · ")
    }
}

/// The source filter above search results: All, then each source the search
/// asked, with its count ("OpenSubtitles (12)").
nonisolated enum SubtitleResultFilter: Hashable, Sendable {
    case all
    case source(SubtitleOrigin)

    func matches(_ candidate: SubtitleCandidate) -> Bool {
        switch self {
        case .all: true
        case .source(let origin): candidate.origin == origin
        }
    }

    /// "All (54)", "Plex (4)", …: All first, then the sources in a fixed order.
    static func tabs(for candidates: [SubtitleCandidate], searched: [SubtitleOrigin]) -> [(filter: Self, title: String)] {
        let order: [SubtitleOrigin] = [.plexSearch, .openSubtitles, .subSource]
        let sources = order.filter { origin in searched.contains(origin) || candidates.contains { $0.origin == origin } }
        return [(.all, "All (\(candidates.count))")] + sources.map { origin in
            let name = origin == .plexSearch ? "Plex" : origin.label
            return (.source(origin), "\(name) (\(candidates.count { $0.origin == origin }))")
        }
    }
}

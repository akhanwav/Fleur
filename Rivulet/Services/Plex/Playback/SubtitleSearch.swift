// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleSearch.swift
//  Rivulet
//
//  "Search Subtitles…", as the player's Subtitles menu and the detail page's
//  Subtitles picker use it: one list from up to three sources, best match first
//  (`SubtitleRanking`).
//
//  - Plex's own search, on a server this account administers: the server
//    searches its subtitle agents (`GET /library/metadata/<id>/subtitles`) and
//    a pick is saved next to the media (`PUT …?key=`), one of the file's
//    streams on that server for every client. Never on a shared server, never
//    for a restricted profile.
//  - OpenSubtitles and SubSource, on any server, when their keys are in
//    `Secrets`: a pick is stored on the Apple TV for that title on that server
//    (`LocalSubtitleStore`). OpenSubtitles is asked with the file's hash
//    (read from the server with two range requests), so a subtitle made for
//    this exact release is marked "Exact match".
//

import Foundation

/// What a search needs to know about the file and the title.
nonisolated struct SubtitleSearchContext: Sendable {
    let serverURL: String
    let token: String
    let ratingKey: String
    /// `LocalSubtitleStore.serverKey`.
    let serverKey: String
    let canUsePlex: Bool
    /// ISO 639-1.
    let language: String
    let fileName: String?
    let fileSize: Int?
    let partKey: String?
    let title: String?
    let year: Int?
    let imdbID: String?
    let tmdbID: Int?
    let isEpisode: Bool
    let season: Int?
    let episode: Int?
    let showTitle: String?
    let showImdbID: String?
    let showTmdbID: Int?
    /// The file's video, from the server: a subtitle's match is scored
    /// against these where the file's name doesn't say.
    var frameRate: Double? = nil
    var resolution: String? = nil
    var codec: String? = nil
    var isAnime = false

    /// What the match is scored against: the file's name, filled in from
    /// the server's media facts.
    var fileFacts: SubtitleMatch.FileFacts {
        var release = ReleaseParser.parse(fileName ?? "")
        release.resolution = release.resolution ?? resolution
        release.codec = release.codec ?? codec
        return SubtitleMatch.FileFacts(release: release, frameRate: frameRate ?? release.frameRate,
                                       season: season, episode: episode, isEpisode: isEpisode)
    }

    var imdbNumber: Int? { Self.number(imdbID) }
    var showImdbNumber: Int? { Self.number(showImdbID) }
    private static func number(_ imdb: String?) -> Int? { imdb.flatMap { Int($0.dropFirst(2)) } }
}

nonisolated struct SubtitleSearchResults: Sendable {
    var candidates: [SubtitleCandidate] = []
    /// One line per source that failed ("OpenSubtitles is busy…").
    var notices: [String] = []
    /// The sources this search asked, for the filter's tabs.
    var searched: [SubtitleOrigin] = []
    /// What each result was scored against; nil when no search ran.
    var file: SubtitleMatch.FileFacts?
    var fileName: String?
    var isAnime = false
}

/// How a pick ended.
enum SubtitleInstall {
    /// The server lists it: the stream, and the item's versions as listed now.
    case plex(stream: PlexStream, media: [PlexMedia])
    /// Stored on the Apple TV.
    case local(LocalSubtitle)
    case failed(String)
}

@MainActor
enum SubtitleSearch {
    /// Admin answers per server URL + token, for the session.
    private static var adminAnswers: [String: Bool] = [:]

    /// Whether Plex's own search may be used: the answer already known for a
    /// server, nil before the first ask.
    static func knownAccess(serverURL: String, token: String) -> Bool? {
        guard PlexUserProfileManager.shared.selectedUser?.restricted != true else { return false }
        return adminAnswers[serverURL + token]
    }

    /// Any search there: Plex's on an administered server, or another source.
    static func isOffered(serverURL: String, token: String) -> Bool {
        hasOtherSources || knownAccess(serverURL: serverURL, token: token) == true
    }

    static var hasOtherSources: Bool { OpenSubtitlesClient.isConfigured || SubSourceClient.isConfigured }

    /// One ask per server at a time.
    private static var asking: [String: Task<Bool, Never>] = [:]

    static func canSearch(serverURL: String, token: String) async -> Bool {
        if let known = knownAccess(serverURL: serverURL, token: token) { return known }
        let key = serverURL + token
        if let task = asking[key] { return await task.value }
        let task = Task { await PlexNetworkManager.shared.canAdministerServer(serverURL: serverURL, authToken: token) }
        asking[key] = task
        let isAdmin = await task.value
        asking[key] = nil
        adminAnswers[key] = isAdmin
        return isAdmin
    }

    /// The subtitle preference's language, else English, as ISO 639-1.
    static var language: String {
        guard case .track(let preferred, _, _, _) = TrackIntentStore.subtitleIntent ?? .off else { return "en" }
        let code = TrackLanguage.normalize(preferred)
        return code.isEmpty ? "en" : Locale.LanguageCode(code).identifier(.alpha2) ?? "en"
    }

    // MARK: - Context

    /// Reads the item (with its external ids, and a show's for an episode) for
    /// a search. `mediaID` is the version the caller describes.
    static func context(serverURL: String, token: String, ratingKey: String, mediaID: String?) async throws
        -> SubtitleSearchContext {
        let network = PlexNetworkManager.shared
        let item = try await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey,
                                                 includeGuids: true)
        let media = item.Media ?? []
        let version = media.first { mediaID != nil && String($0.id) == mediaID } ?? media.first
        let part = version?.Part?.first
        let isEpisode = item.type == "episode"
        var show: PlexMetadata?
        if isEpisode, let showKey = item.grandparentRatingKey {
            show = try? await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: showKey,
                                                  includeGuids: true)
        }
        let canUsePlex = await canSearch(serverURL: serverURL, token: token)
        let video = part?.Stream?.first { $0.streamType == 1 }
        let genres = Set(item.genreTags + (show?.genreTags ?? []))
        let japaneseAudio = part?.Stream?.contains { $0.streamType == 2 && ["ja", "jpn"].contains($0.languageCode ?? "") } ?? false
        var context = SubtitleSearchContext(
            serverURL: serverURL, token: token, ratingKey: ratingKey,
            serverKey: LocalSubtitleStore.serverKey(serverURL: serverURL), canUsePlex: canUsePlex,
            language: language,
            fileName: part?.file.map { ($0 as NSString).lastPathComponent },
            fileSize: part?.size, partKey: part?.key,
            title: item.title, year: item.year,
            imdbID: imdb(item), tmdbID: item.tmdbId,
            isEpisode: isEpisode, season: item.parentIndex, episode: item.index,
            showTitle: item.grandparentTitle ?? show?.title,
            showImdbID: show.flatMap(imdb), showTmdbID: show?.tmdbId ?? item.showTmdbId)
        context.frameRate = video?.frameRate
        context.resolution = version?.videoResolution.flatMap(Self.resolution)
        context.codec = version?.videoCodec.flatMap(Self.codec)
        context.isAnime = genres.contains("anime") || (genres.contains("animation") && japaneseAudio)
        return context
    }

    /// Plex's "1080", "4k", "sd" as a release name writes it.
    nonisolated static func resolution(_ plex: String) -> String? {
        switch plex.lowercased() {
        case "4k", "2160": "2160p"
        case "1080", "720", "576", "480": "\(plex)p"
        default: nil
        }
    }

    nonisolated static func codec(_ plex: String) -> String? {
        switch plex.lowercased() {
        case "h264", "avc": "H.264"
        case "hevc", "h265": "H.265"
        case "av1": "AV1"
        default: nil
        }
    }

    private static func imdb(_ item: PlexMetadata) -> String? {
        (item.Guid ?? []).lazy.compactMap(\.id).first { $0.hasPrefix("imdb://") }.map { String($0.dropFirst(7)) }
    }

    // MARK: - Search

    static func search(_ context: SubtitleSearchContext) async -> SubtitleSearchResults {
        async let plex = searchPlex(context)
        async let openSubtitles = searchOpenSubtitles(context)
        async let subSource = searchSubSource(context)
        let parts = await [plex, openSubtitles, subSource]
        var results = SubtitleSearchResults()
        for part in parts {
            results.candidates += part.candidates
            results.notices += part.notices
            results.searched += part.searched
        }
        let facts = context.fileFacts
        results.file = facts
        results.fileName = context.fileName
        results.isAnime = context.isAnime
        results.candidates = SubtitleSort.sorted(results.candidates.map { candidate in
            var scored = candidate
            let info = candidate.info
            scored.matchPercent = SubtitleMatch.percent(info, frameRate: candidate.frameRate, season: candidate.season,
                                                        episode: candidate.episode, isHashMatch: candidate.isHashMatch,
                                                        file: facts)
            scored.matchKind = SubtitleMatch.kind(info, isHashMatch: candidate.isHashMatch, file: facts)
            return scored
        })
        print("[SubtitleSearch] \(results.candidates.count) results "
              + "(\(results.candidates.filter(\.isHashMatch).count) exact), notices: \(results.notices)")
        return results
    }

    private static func searchPlex(_ context: SubtitleSearchContext) async -> SubtitleSearchResults {
        guard context.canUsePlex else { return SubtitleSearchResults() }
        let searched: [SubtitleOrigin] = [.plexSearch]
        do {
            let streams = try await PlexNetworkManager.shared.searchSubtitles(
                serverURL: context.serverURL, authToken: context.token, ratingKey: context.ratingKey,
                language: context.language)
            return SubtitleSearchResults(candidates: streams.map { stream in
                SubtitleCandidate(
                    id: "plex:\(stream.id)", origin: .plexSearch,
                    release: stream.title ?? stream.displayTitle ?? "",
                    language: stream.languageTag ?? stream.languageCode, isHearingImpaired: stream.hearingImpaired ?? false,
                    isForced: stream.forced ?? false, downloads: nil, rating: nil, isHashMatch: false,
                    payload: .plex(stream), format: stream.codec)
            }, searched: searched)
        } catch {
            return SubtitleSearchResults(notices: ["Plex search failed."], searched: searched)
        }
    }

    private static func searchOpenSubtitles(_ context: SubtitleSearchContext) async -> SubtitleSearchResults {
        guard OpenSubtitlesClient.isConfigured else { return SubtitleSearchResults() }
        let hash = await fileHash(context)
        do {
            return SubtitleSearchResults(candidates: try await OpenSubtitlesClient.shared.search(context, hash: hash),
                                         searched: [.openSubtitles])
        } catch {
            return SubtitleSearchResults(notices: [message(error, .openSubtitles)], searched: [.openSubtitles])
        }
    }

    private static func searchSubSource(_ context: SubtitleSearchContext) async -> SubtitleSearchResults {
        guard SubSourceClient.isConfigured else { return SubtitleSearchResults() }
        do {
            return SubtitleSearchResults(candidates: try await SubSourceClient.shared.search(context),
                                         searched: [.subSource])
        } catch {
            return SubtitleSearchResults(notices: [message(error, .subSource)], searched: [.subSource])
        }
    }

    private static func message(_ error: Error, _ origin: SubtitleOrigin) -> String {
        (error as? SubtitleSourceError)?.message(origin) ?? "\(origin.label) couldn't be reached."
    }

    /// The file's OpenSubtitles hash, from its first and last 64 KiB on the server.
    private static var hashes: [String: String] = [:]

    private static func fileHash(_ context: SubtitleSearchContext) async -> String? {
        guard let partKey = context.partKey, let size = context.fileSize, size >= OpenSubtitlesHash.chunk * 2 else {
            return nil
        }
        let cacheKey = "\(context.serverKey)|\(partKey)|\(size)"
        if let known = hashes[cacheKey] { return known }
        let network = PlexNetworkManager.shared
        let chunk = OpenSubtitlesHash.chunk
        async let head = network.partBytes(serverURL: context.serverURL, authToken: context.token,
                                           partKey: partKey, offset: 0, length: chunk)
        async let tail = network.partBytes(serverURL: context.serverURL, authToken: context.token,
                                           partKey: partKey, offset: size - chunk, length: chunk)
        guard let head = try? await head, let tail = try? await tail,
              let hash = OpenSubtitlesHash.hash(size: size, head: head, tail: tail) else {
            print("[SubtitleSearch] file hash unavailable")
            return nil
        }
        hashes[cacheKey] = hash
        return hash
    }

    // MARK: - Install

    /// Fetches a pick. A Plex result is saved on the server and waited for;
    /// any other is stored on the Apple TV. `media` picks the version the caller
    /// describes from the refreshed item, `known` the subtitle ids it already
    /// had. nil when `stillWanted` turned false.
    static func install(_ candidate: SubtitleCandidate, context: SubtitleSearchContext, known: Set<Int>,
                        media: @escaping ([PlexMedia]) -> [PlexMedia],
                        stillWanted: @escaping () -> Bool = { true }) async -> SubtitleInstall? {
        switch candidate.payload {
        case .plex(let result):
            return await downloadFromPlex(result, context: context, known: known, media: media, stillWanted: stillWanted)
        case .openSubtitles(let fileID):
            let text: String
            do {
                text = try await OpenSubtitlesClient.shared.download(fileID: fileID)
            } catch {
                print("[SubtitleSearch] OpenSubtitles download failed: \(error)")
                return .failed(message(error, .openSubtitles))
            }
            return store(text, format: "srt", candidate: candidate, context: context)
        case .subSource(let subtitleID):
            let file: (text: String, format: String)
            do {
                file = try await SubSourceClient.shared.download(subtitleID: subtitleID, context: context)
            } catch {
                print("[SubtitleSearch] SubSource download failed: \(error)")
                return .failed(message(error, .subSource))
            }
            return store(file.text, format: file.format, candidate: candidate, context: context)
        }
    }

    /// A failure here is the Apple TV's, never the source's: it says so.
    private static func store(_ text: String, format: String, candidate: SubtitleCandidate,
                              context: SubtitleSearchContext) -> SubtitleInstall {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(SubtitleSourceError.noFile.message(candidate.origin))
        }
        let language = candidate.language.flatMap { Locale.LanguageCode($0).identifier(.alpha2) } ?? context.language
        do {
            return .local(try LocalSubtitleStore.save(
                text: text, format: format, server: context.serverKey, ratingKey: context.ratingKey,
                origin: candidate.origin, release: candidate.release, language: language,
                isHearingImpaired: candidate.isHearingImpaired, isForced: candidate.isForced))
        } catch {
            print("[SubtitleSearch] saving the subtitles failed: \(error)")
            return .failed("The subtitles downloaded but couldn't be saved on this Apple TV.")
        }
    }

    /// The longest a server is given to list a Plex download.
    static let plexArrivalWindow: TimeInterval = 30

    static let plexServiceFailed = "Plex's subtitle service isn't working right now. Try another source."

    /// Saves a Plex result next to the media, then waits for the server to list
    /// it. PMS answers the PUT at once and fetches the file from Plex's provider
    /// afterwards, answering 200 even when that fetch fails: so a pick the
    /// server already has is taken as is, the provider is asked first, and the
    /// wait polls past the cache with a growing interval.
    private static func downloadFromPlex(_ result: PlexStream, context: SubtitleSearchContext, known: Set<Int>,
                                         media: @escaping ([PlexMedia]) -> [PlexMedia],
                                         stillWanted: @escaping () -> Bool) async -> SubtitleInstall? {
        guard let resultKey = result.key else { return .failed("This result can't be downloaded.") }
        let network = PlexNetworkManager.shared
        let started = Date()
        func log(_ text: String) {
            print(String(format: "[SubtitleSearch] +%.1fs ", Date().timeIntervalSince(started)) + text)
        }
        func listed(_ versions: [PlexMedia]) -> PlexStream? {
            let subtitles = versions.first?.Part?.first?.Stream?.filter { $0.isSubtitle && $0.key != nil } ?? []
            if let sourceKey = result.sourceKey, let same = subtitles.first(where: { $0.sourceKey == sourceKey }) {
                return same
            }
            return subtitles.first { !known.contains($0.id) && !LocalSubtitleStore.isLocal(streamID: $0.id) }
        }

        // Picked again: the server keeps one copy, under the id it already had.
        if result.sourceKey != nil,
           let versions = try? await network.freshSubtitleStreams(serverURL: context.serverURL, authToken: context.token,
                                                                  ratingKey: context.ratingKey),
           let stream = media(versions).first?.Part?.first?.Stream?.first(where: {
               $0.isSubtitle && $0.sourceKey == result.sourceKey }) {
            log("already listed as \(stream.id)")
            return .plex(stream: stream, media: media(versions))
        }
        if let sourceKey = result.sourceKey, await network.plexSubtitleSourceAvailable(sourceKey: sourceKey) == false {
            log("provider refuses \(sourceKey)")
            return .failed(plexServiceFailed)
        }
        do {
            try await network.downloadSubtitle(serverURL: context.serverURL, authToken: context.token,
                                               ratingKey: context.ratingKey, resultKey: resultKey)
            log("PUT accepted for \(resultKey)")
        } catch {
            log("PUT failed: \(error)")
            return .failed("The server refused the download.")
        }
        var interval: TimeInterval = 1
        var polls = 0
        while Date().timeIntervalSince(started) < plexArrivalWindow {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, stillWanted() else { return nil }
            interval = min(interval + 0.5, 3)
            polls += 1
            // A slow or failed poll is one miss, not the end of the wait.
            guard let versions = try? await network.freshSubtitleStreams(
                serverURL: context.serverURL, authToken: context.token, ratingKey: context.ratingKey) else {
                log("poll \(polls) failed")
                continue
            }
            guard stillWanted() else { return nil }
            let picked = media(versions)
            if let added = listed(picked) {
                log("listed as \(added.id) after \(polls) polls")
                return .plex(stream: added, media: picked)
            }
        }
        log("not listed after \(polls) polls")
        if let sourceKey = result.sourceKey, await network.plexSubtitleSourceAvailable(sourceKey: sourceKey) == false {
            return .failed(plexServiceFailed)
        }
        return .failed("The server didn't add the subtitles. Try another result.")
    }
}

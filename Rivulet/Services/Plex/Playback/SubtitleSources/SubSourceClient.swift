//
//  SubSourceClient.swift
//  Rivulet
//
//  SubSource's API (api.subsource.net/api/v1) with the key in `Secrets`: find
//  the title by IMDb id (a show by its id and season), list its subtitles in one
//  language, download one as a ZIP. Requests are limited per minute, hour and
//  day; a 429 names when the window resets.
//

import Compression
import Foundation

actor SubSourceClient {
    static let shared = SubSourceClient()

    nonisolated static var isConfigured: Bool { !Secrets.subSourceAPIKey.isEmpty }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// A title's SubSource id, by its IMDb id and season.
    private var movieIDs: [String: String] = [:]

    private func get(_ path: String, _ query: [(String, String)]) async throws -> Data {
        var components = URLComponents(string: "https://api.subsource.net/api/v1/" + path)
        components?.queryItems = ([("api_key", Secrets.subSourceAPIKey)] + query).map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw SubtitleSourceError.server(0) }
        var request = URLRequest(url: url)
        request.setValue(Secrets.subSourceAPIKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("Rivulet/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: return data
        case 401, 403: throw SubtitleSourceError.badKey
        case 404: return Data()
        case 429: throw SubtitleSourceError.rateLimited(retryAfter: Self.retryAfter(http, data))
        case let status: throw SubtitleSourceError.server(status)
        }
    }

    /// `X-RateLimit-Reset` (an ISO time), else the body's `retryAfter` seconds.
    private static func retryAfter(_ response: HTTPURLResponse?, _ data: Data) -> TimeInterval? {
        if let reset = response?.value(forHTTPHeaderField: "X-RateLimit-Reset") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: reset) ?? ISO8601DateFormatter().date(from: reset)
            if let date { return max(0, date.timeIntervalSinceNow) }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["retryAfter"] as? NSNumber)?.doubleValue
    }

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    // MARK: Search

    private func movieID(_ context: SubtitleSearchContext) async throws -> String? {
        let imdb = context.isEpisode ? context.showImdbID : context.imdbID
        let cacheKey = "\(imdb ?? context.title ?? "")|\(context.season ?? -1)"
        if let known = movieIDs[cacheKey] { return known }
        var query: [(String, String)]
        if let imdb {
            query = [("searchType", "imdb"), ("imdb", imdb)]
        } else if let title = context.isEpisode ? context.showTitle : context.title {
            query = [("searchType", "text"), ("q", title.lowercased())]
        } else {
            return nil
        }
        if context.isEpisode, let season = context.season { query.append(("season", String(season))) }
        let results = Self.json(try await get("movies/search", query))["data"] as? [[String: Any]] ?? []
        // A text search can find several: the one from the title's year.
        let match = results.first { item in
            imdb != nil || context.year == nil || (item["releaseYear"] as? NSNumber)?.intValue == context.year
        } ?? results.first
        let id = Self.string(match?["movieId"])
        if let id { movieIDs[cacheKey] = id }
        return id
    }

    func search(_ context: SubtitleSearchContext) async throws -> [SubtitleCandidate] {
        guard let movieID = try await movieID(context) else { return [] }
        let language = Locale(identifier: "en").localizedString(forLanguageCode: context.language)?.lowercased() ?? "english"
        var query = [("movieId", movieID), ("language", language), ("limit", "100")]
        if context.isEpisode {
            if let season = context.season { query.append(("seasonNumber", String(season))) }
            if let episode = context.episode { query.append(("episodeNumber", String(episode))) }
        }
        let items = Self.json(try await get("subtitles", query))["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = Self.string(item["subtitleId"] ?? item["id"]) else { return nil }
            let releases: [String] = (item["releaseInfo"] as? [String])
                ?? (item["releaseInfo"] as? String).map { [$0] } ?? []
            let release = releases.max { SubtitleRanking.releaseScore($0, fileName: context.fileName ?? "")
                < SubtitleRanking.releaseScore($1, fileName: context.fileName ?? "") } ?? ""
            let downloads = ["downloads", "downloadCount", "download_count"].lazy
                .compactMap { (item[$0] as? NSNumber)?.intValue }.first
            return SubtitleCandidate(
                id: "ss:\(id)", origin: .subSource, release: release,
                language: context.language,
                isHearingImpaired: item["hearingImpaired"] as? Bool ?? false,
                isForced: (item["foreignParts"] as? Bool) ?? false,
                downloads: downloads, rating: Self.rating(item["rating"]),
                isHashMatch: false,
                payload: .subSource(subtitleID: id))
        }
    }

    /// A score out of 10: a number as is, or good over good and bad votes.
    private static func rating(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let votes = value as? [String: Any],
              let good = (votes["good"] as? NSNumber)?.doubleValue,
              let bad = (votes["bad"] as? NSNumber)?.doubleValue, good + bad > 0 else { return nil }
        return good / (good + bad) * 10
    }

    // MARK: Download

    /// The subtitle file's text and format, out of the ZIP SubSource sends.
    func download(subtitleID: String, context: SubtitleSearchContext) async throws -> (text: String, format: String) {
        let data = try await get("subtitles/\(subtitleID)/download", [])
        guard let file = ZipArchive.subtitleFile(in: data, season: context.season, episode: context.episode) else {
            throw SubtitleSourceError.noFile
        }
        return (SubtitleText.decode(file.data), file.format)
    }
}

/// Just enough ZIP to take a subtitle out of an archive: the central
/// directory, stored and deflated entries.
nonisolated enum ZipArchive {
    struct Entry { let name: String; let data: Data }

    static let subtitleFormats = ["srt", "ass", "ssa", "vtt"]

    static func entries(in data: Data) -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 3 < bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }
        guard bytes.count >= 22 else { return [] }
        // The end-of-central-directory record, within the last 64 KiB.
        var end = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while end >= floor, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= floor else { return [] }
        let count = u16(end + 10)
        var at = u32(end + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard u32(at) == 0x0201_4b50 else { break }
            let method = u16(at + 10)
            let compressed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            let local = u32(at + 42)
            let name = String(decoding: bytes[min(at + 46, bytes.count)..<min(at + 46 + nameLength, bytes.count)], as: UTF8.self)
            at += 46 + nameLength + extra + comment
            guard u32(local) == 0x0403_4b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }
            let body = Data(bytes[start..<start + compressed])
            switch method {
            case 0: entries.append(Entry(name: name, data: body))
            case 8: if let inflated = inflate(body, size: size) { entries.append(Entry(name: name, data: inflated)) }
            default: continue
            }
        }
        return entries
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` reads.
    static func inflate(_ data: Data, size: Int) -> Data? {
        // A subtitle is small: a claim of more than 20 MB is a broken archive.
        guard size > 0, size <= 20_000_000, !data.isEmpty else { return size == 0 ? Data() : nil }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out -> Int in
            data.withUnsafeBytes { input -> Int in
                guard let destination = out.bindMemory(to: UInt8.self).baseAddress,
                      let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destination, size, source, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? output : nil
    }

    /// The archive's subtitle for the episode ("S02E05" in its name) when it
    /// holds a season's, else its first.
    static func subtitleFile(in data: Data, season: Int?, episode: Int?) -> (data: Data, format: String)? {
        let subtitles = entries(in: data).filter { entry in
            !entry.name.hasPrefix("__MACOSX") && subtitleFormats.contains((entry.name as NSString).pathExtension.lowercased())
        }
        var pick = subtitles.first
        if subtitles.count > 1, let season, let episode {
            let tag = String(format: "s%02de%02d", season, episode)
            pick = subtitles.first { $0.name.lowercased().contains(tag) } ?? pick
        }
        guard let pick else { return nil }
        let ext = (pick.name as NSString).pathExtension.lowercased()
        return (pick.data, ext == "ssa" ? "ass" : ext)
    }
}

/// A downloaded subtitle as UTF-8 text, whatever it was written in.
nonisolated enum SubtitleText {
    static func decode(_ data: Data) -> String {
        var text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            var converted: NSString?
            let encoding = NSString.stringEncoding(for: data, encodingOptions: [
                .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue],
            ], convertedString: &converted, usedLossyConversion: nil)
            text = encoding != 0 ? (converted as String? ?? "") : String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }
}

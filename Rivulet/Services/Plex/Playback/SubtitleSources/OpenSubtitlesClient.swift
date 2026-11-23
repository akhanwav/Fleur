//
//  OpenSubtitlesClient.swift
//  Rivulet
//
//  OpenSubtitles.com REST API (api.opensubtitles.com/api/v1), signed in with
//  the account in `Secrets`. Search needs only the API key; a download needs
//  the account's token and counts against its daily quota (406 when spent).
//

import Foundation

/// The OpenSubtitles movie hash: the file size plus the 64-bit little-endian
/// words of its first and last 64 KiB, wrapping, as 16 lower-case hex digits.
nonisolated enum OpenSubtitlesHash {
    static let chunk = 65_536

    static func hash(size: Int, head: Data, tail: Data) -> String? {
        guard size >= chunk * 2, head.count == chunk, tail.count == chunk else { return nil }
        var value = UInt64(size)
        for block in [head, tail] {
            block.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: chunk, by: 8) {
                    value &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                }
            }
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

actor OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient()

    nonisolated static var isConfigured: Bool { !Secrets.openSubtitlesAPIKey.isEmpty }
    private nonisolated static var hasAccount: Bool {
        !Secrets.openSubtitlesUsername.isEmpty && !Secrets.openSubtitlesPassword.isEmpty
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// The host a sign-in names (a VIP account is sent to its own).
    private var host = "api.opensubtitles.com"
    private var token: String?
    private var tokenDate: Date?

    private var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Rivulet v\(version)"
    }

    private func request(_ path: String, query: [(String, String)] = [], method: String = "GET",
                         body: [String: Any]? = nil, authorized: Bool = false) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/" + path
        // Sorted and lower-case, or the API redirects (and a redirect drops the key).
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.0 < $1.0 }.map { URLQueryItem(name: $0.0, value: $0.1.lowercased()) }
        }
        guard let url = components.url else { throw SubtitleSourceError.server(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Secrets.openSubtitlesAPIKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authorized, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int, HTTPURLResponse?) {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http)
    }

    private static func error(status: Int, data: Data, response: HTTPURLResponse?) -> SubtitleSourceError {
        switch status {
        case 401: return .signInFailed
        case 403: return .badKey
        case 406:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return .quotaExceeded(resets: json?["reset_time"] as? String)
        case 429:
            let after = response?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                ?? response?.value(forHTTPHeaderField: "ratelimit-reset").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: after)
        default: return .server(status)
        }
    }

    // MARK: Sign-in

    /// One sign-in a day: the token lasts 24 hours.
    private func signIn(force: Bool = false) async throws {
        if !force, token != nil, let tokenDate, Date().timeIntervalSince(tokenDate) < 23 * 3600 { return }
        guard Self.hasAccount else { throw SubtitleSourceError.signInFailed }
        host = "api.opensubtitles.com"
        let login = try request("login", method: "POST",
                                body: ["username": Secrets.openSubtitlesUsername, "password": Secrets.openSubtitlesPassword])
        let (data, status, response) = try await send(login)
        guard status == 200 else {
            throw status == 401 || status == 400 ? SubtitleSourceError.signInFailed
                : Self.error(status: status, data: data, response: response)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let newToken = json?["token"] as? String else { throw SubtitleSourceError.signInFailed }
        token = newToken
        tokenDate = Date()
        if let base = json?["base_url"] as? String, !base.isEmpty {
            host = base.replacingOccurrences(of: "https://", with: "").split(separator: "/").first.map(String.init) ?? host
        }
    }

    // MARK: Search

    func search(_ context: SubtitleSearchContext, hash: String?) async throws -> [SubtitleCandidate] {
        var query: [(String, String)] = [("languages", context.language),
                                         ("ai_translated", "exclude"), ("machine_translated", "exclude")]
        if let hash { query.append(("moviehash", hash)) }
        if context.isEpisode {
            if let imdb = context.showImdbNumber { query.append(("parent_imdb_id", String(imdb))) }
            else if let tmdb = context.showTmdbID { query.append(("parent_tmdb_id", String(tmdb))) }
            else if let title = context.showTitle { query.append(("query", title)) }
            if let season = context.season { query.append(("season_number", String(season))) }
            if let episode = context.episode { query.append(("episode_number", String(episode))) }
        } else if let imdb = context.imdbNumber {
            query.append(("imdb_id", String(imdb)))
        } else if let tmdb = context.tmdbID {
            query.append(("tmdb_id", String(tmdb)))
        } else if let title = context.title {
            query.append(("query", title))
            if let year = context.year { query.append(("year", String(year))) }
        }
        let (data, status, response) = try await send(request("subtitles", query: query))
        guard status == 200 else { throw Self.error(status: status, data: data, response: response) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = json?["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let file = (attributes["files"] as? [[String: Any]])?.first,
                  let fileID = (file["file_id"] as? NSNumber)?.intValue else { return nil }
            let release = (attributes["release"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (file["file_name"] as? String) ?? ""
            let feature = attributes["feature_details"] as? [String: Any]
            let fps = (attributes["fps"] as? NSNumber)?.doubleValue
            var candidate = SubtitleCandidate(
                id: "os:\(fileID)", origin: .openSubtitles, release: release,
                language: attributes["language"] as? String,
                isHearingImpaired: attributes["hearing_impaired"] as? Bool ?? false,
                isForced: attributes["foreign_parts_only"] as? Bool ?? false,
                downloads: (attributes["download_count"] as? NSNumber)?.intValue,
                rating: (attributes["ratings"] as? NSNumber)?.doubleValue,
                isHashMatch: attributes["moviehash_match"] as? Bool ?? false,
                payload: .openSubtitles(fileID: fileID))
            // Downloads are asked for as SRT.
            candidate.format = "srt"
            candidate.season = (feature?["season_number"] as? NSNumber)?.intValue
            candidate.episode = (feature?["episode_number"] as? NSNumber)?.intValue
            if let fps, fps > 0 { candidate.frameRate = fps }
            return candidate
        }
    }

    // MARK: Download

    /// The file's text (SRT). Signs in first; a token the server has dropped
    /// is renewed once.
    func download(fileID: Int) async throws -> String {
        try await signIn()
        var attempt = 0
        while true {
            let (data, status, response) = try await send(
                request("download", method: "POST", body: ["file_id": fileID, "sub_format": "srt"], authorized: true))
            if status == 401, attempt == 0 {
                attempt += 1
                try await signIn(force: true)
                continue
            }
            guard status == 200 else { throw Self.error(status: status, data: data, response: response) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let link = (json?["link"] as? String).flatMap(URL.init(string:)) else { throw SubtitleSourceError.noFile }
            let (file, fileResponse) = try await session.data(from: link)
            guard (fileResponse as? HTTPURLResponse)?.statusCode == 200, !file.isEmpty else {
                throw SubtitleSourceError.noFile
            }
            return SubtitleText.decode(file)
        }
    }
}

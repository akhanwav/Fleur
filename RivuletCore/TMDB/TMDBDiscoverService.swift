// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBDiscoverService.swift
//  Rivulet
//
//  Fetches list/discover/details endpoints directly from TMDB, with caching.
//

import Foundation

actor TMDBDiscoverService {
    static let shared = TMDBDiscoverService()

    private let session: URLSession
    private let listCacheTTL: TimeInterval = 60 * 60                // 1 hour: prefer fresh
    private let listDiskFallbackTTL: TimeInterval = 60 * 60 * 24 * 7 // 1 week: usable cold-launch fallback
    private let detailCacheTTL: TimeInterval = 60 * 60 * 24 * 30    // 30 days
    /// Bump whenever `TMDBItemDetail`'s decoded shape grows a field that a
    /// cache HIT must not silently omit (append_to_response additions). An
    /// old cache file lacks the new `version` key entirely, so decoding it
    /// as this now-required field throws, `loadDetailFromDisk`'s `try?`
    /// turns that into a miss, and the title refetches with the new fields
    /// instead of serving a stale, append-less entry for up to 30 days.
    private static let detailCacheVersion = 2

    private struct ListCacheEntry {
        let fetchedAt: Date
        let items: [TMDBListItem]
    }

    private var listCache: [TMDBDiscoverSection: ListCacheEntry] = [:]
    /// In-memory only (unlike `listCache`): "For You" results depend on the
    /// user's evolving watch profile, so a short-lived cache is enough to
    /// absorb repeat loads without persisting a stale recommendation set
    /// across app launches.
    private var discoverCache: [String: ListCacheEntry] = [:]
    private let listCacheDirectory: URL
    private let detailCacheDirectory: URL

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        listCacheDirectory = caches.appendingPathComponent("TMDBDiscoverListCache", isDirectory: true)
        detailCacheDirectory = caches.appendingPathComponent("TMDBDiscoverDetailCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: listCacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: detailCacheDirectory, withIntermediateDirectories: true)
    }

    func fetchSection(_ section: TMDBDiscoverSection) async -> [TMDBListItem] {
        // 1) Hot in-memory cache (1h)
        if let cached = listCache[section],
           Date().timeIntervalSince(cached.fetchedAt) < listCacheTTL {
            return cached.items
        }

        // 2) Warm disk cache (1h): same TTL but survives launches
        if let cached = loadListFromDisk(section: section, maxAge: listCacheTTL) {
            listCache[section] = ListCacheEntry(fetchedAt: cached.savedAt, items: cached.items)
            return cached.items
        }

        struct ListResponse: Decodable {
            let results: [TMDBListItem]
        }

        let data: Data
        do {
            data = try await fetchData(path: section.tmdbPath)
        } catch {
            // 3) Cold disk fallback (up to 1 week stale): better than nothing
            if let cached = loadListFromDisk(section: section, maxAge: listDiskFallbackTTL) {
                return cached.items
            }
            return []
        }

        do {
            let response = try JSONDecoder().decode(ListResponse.self, from: data)
            // Stamp media type from caller (list endpoints don't include media_type).
            let stamped = response.results.map { item -> TMDBListItem in
                TMDBListItem(
                    id: item.id,
                    title: item.title,
                    overview: item.overview,
                    posterPath: item.posterPath,
                    backdropPath: item.backdropPath,
                    releaseDate: item.releaseDate,
                    voteAverage: item.voteAverage,
                    mediaType: section.mediaType
                )
            }
            listCache[section] = ListCacheEntry(fetchedAt: Date(), items: stamped)
            saveListToDisk(stamped, section: section)
            return stamped
        } catch {
            if let cached = loadListFromDisk(section: section, maxAge: listDiskFallbackTTL) {
                return cached.items
            }
            return []
        }
    }

    func fetchDetail(tmdbId: Int, type: TMDBMediaType) async -> TMDBItemDetail? {
        if let cached = loadDetailFromDisk(tmdbId: tmdbId, type: type) {
            return cached
        }

        // One request for the whole below-fold: credits (cast/crew, with
        // photos), recommendations (More Like This), watch/providers (Where
        // to Watch), and videos (the Trailer button) all ride along on the
        // same cached call instead of four separate round-trips. TMDB
        // accepts a comma list, slash paths included.
        let appendItems = [URLQueryItem(name: "append_to_response", value: "credits,recommendations,watch/providers,videos")]
        guard let data = try? await fetchData(path: "\(type.rawValue)/\(tmdbId)", queryItems: appendItems),
              let decoded = try? JSONDecoder().decode(TMDBItemDetail.self, from: data) else {
            return nil
        }
        // Recommendations are same-type as the title queried (a movie's
        // recommendations are movies, a show's are shows) but TMDB's results
        // omit media_type for this endpoint, so TMDBListItem's decoder
        // defaults to .movie — stamp the real type, mirroring fetchSection.
        let stampedRecommendations = decoded.recommendations.map { item -> TMDBListItem in
            TMDBListItem(
                id: item.id,
                title: item.title,
                overview: item.overview,
                posterPath: item.posterPath,
                backdropPath: item.backdropPath,
                releaseDate: item.releaseDate,
                voteAverage: item.voteAverage,
                mediaType: type
            )
        }
        let detail = TMDBItemDetail(
            id: decoded.id,
            title: decoded.title,
            overview: decoded.overview,
            posterPath: decoded.posterPath,
            backdropPath: decoded.backdropPath,
            releaseDate: decoded.releaseDate,
            runtime: decoded.runtime,
            genres: decoded.genres,
            voteAverage: decoded.voteAverage,
            cast: decoded.cast,
            crew: decoded.crew,
            createdBy: decoded.createdBy,
            numberOfSeasons: decoded.numberOfSeasons,
            recommendations: stampedRecommendations,
            watchProviders: decoded.watchProviders,
            videos: decoded.videos,
            mediaType: type
        )
        saveDetailToDisk(detail, tmdbId: tmdbId, type: type)
        return detail
    }

    // MARK: - Discover (For You)

    func discover(type: TMDBMediaType, withGenres: [Int], withKeywords: [Int]) async -> [TMDBListItem] {
        let cacheKey = Self.discoverCacheKey(type: type, withGenres: withGenres, withKeywords: withKeywords)
        if let cached = discoverCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < listCacheTTL {
            return cached.items
        }

        var items = [URLQueryItem]()
        if !withGenres.isEmpty {
            items.append(URLQueryItem(name: "with_genres", value: withGenres.map(String.init).joined(separator: "|")))
        }
        if !withKeywords.isEmpty {
            items.append(URLQueryItem(name: "with_keywords", value: withKeywords.map(String.init).joined(separator: "|")))
        }
        items.append(URLQueryItem(name: "sort_by", value: "popularity.desc"))

        struct ListResponse: Decodable { let results: [TMDBListItem] }

        guard let data = try? await fetchData(path: "discover/\(type.rawValue)", queryItems: items),
              let response = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            return []
        }
        let stamped = response.results.map { item in
            TMDBListItem(
                id: item.id,
                title: item.title,
                overview: item.overview,
                posterPath: item.posterPath,
                backdropPath: item.backdropPath,
                releaseDate: item.releaseDate,
                voteAverage: item.voteAverage,
                mediaType: type
            )
        }
        discoverCache[cacheKey] = ListCacheEntry(fetchedAt: Date(), items: stamped)
        return stamped
    }

    private static func discoverCacheKey(type: TMDBMediaType, withGenres: [Int], withKeywords: [Int]) -> String {
        "\(type.rawValue)|\(withGenres.sorted().map(String.init).joined(separator: ","))"
            + "|\(withKeywords.sorted().map(String.init).joined(separator: ","))"
    }

    // MARK: - Search and Trending (Search page)

    /// Lists that mix movies, shows and people (`search/multi`,
    /// `trending/all`): each result decodes on its own, and a person or any
    /// other unreadable entry is skipped instead of failing the whole page.
    private struct MixedListResponse: Decodable {
        let results: [TMDBListItem]

        private enum CodingKeys: String, CodingKey { case results }
        private struct Skipped: Decodable {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var array = try c.nestedUnkeyedContainer(forKey: .results)
            var items: [TMDBListItem] = []
            while !array.isAtEnd {
                if let item = try? array.decode(TMDBListItem.self) {
                    items.append(item)
                } else {
                    _ = try? array.decode(Skipped.self)
                }
            }
            results = items
        }
    }

    /// Queries already asked, for the hour. Suggestions ask on every pause in
    /// typing, and one title's variants recur keystroke to keystroke.
    private var searchCache: [String: ListCacheEntry] = [:]

    /// Movies and shows for `query` from `search/multi`, people left out.
    /// Empty on any failure: suggestions still have the library's own.
    func searchMulti(_ query: String) async -> [TMDBListItem] {
        let key = query.lowercased()
        if let cached = searchCache[key], Date().timeIntervalSince(cached.fetchedAt) < listCacheTTL {
            return cached.items
        }
        guard let data = try? await fetchData(path: "search/multi", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false")
        ]), let response = try? JSONDecoder().decode(MixedListResponse.self, from: data) else {
            return []
        }
        searchCache[key] = ListCacheEntry(fetchedAt: Date(), items: response.results)
        return response.results
    }

    private static let trendingWeekName = "searchTrendingWeek"
    private var trendingWeek: ListCacheEntry?

    /// This week's trending movies and shows, cached as the Discover lists are:
    /// an hour fresh, a week as the fallback when TMDB cannot be reached.
    func trendingThisWeek() async -> [TMDBListItem] {
        if let trendingWeek, Date().timeIntervalSince(trendingWeek.fetchedAt) < listCacheTTL {
            return trendingWeek.items
        }
        if let cached = loadListFromDisk(name: Self.trendingWeekName, maxAge: listCacheTTL) {
            trendingWeek = ListCacheEntry(fetchedAt: cached.savedAt, items: cached.items)
            return cached.items
        }
        guard let data = try? await fetchData(path: "trending/all/week"),
              let response = try? JSONDecoder().decode(MixedListResponse.self, from: data) else {
            return loadListFromDisk(name: Self.trendingWeekName, maxAge: listDiskFallbackTTL)?.items ?? []
        }
        trendingWeek = ListCacheEntry(fetchedAt: Date(), items: response.results)
        saveListToDisk(response.results, name: Self.trendingWeekName)
        return response.results
    }

    /// Other titles TMDB knows a movie or show by, as TMDB writes them.
    /// Cached for the session: a title is asked about at most once.
    private var alternativeTitleCache: [String: [String]] = [:]

    func alternativeTitles(tmdbId: Int, type: TMDBMediaType) async -> [String] {
        let key = "\(type.rawValue)_\(tmdbId)"
        if let cached = alternativeTitleCache[key] { return cached }
        struct Entry: Decodable { let title: String }
        // Movies answer under `titles`, shows under `results`.
        struct Response: Decodable { let titles: [Entry]?; let results: [Entry]? }
        guard let data = try? await fetchData(path: "\(type.rawValue)/\(tmdbId)/alternative_titles"),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let titles = (response.titles ?? response.results ?? []).map(\.title)
        alternativeTitleCache[key] = titles
        return titles
    }

    // MARK: - Season episodes (episode descriptions a server lacks)

    /// One episode of a TMDB season, as `tv/{id}/season/{n}` lists it.
    struct SeasonEpisode: Codable, Sendable {
        let episodeNumber: Int
        let overview: String?
        let airDate: String?

        enum CodingKeys: String, CodingKey {
            case episodeNumber = "episode_number"
            case overview
            case airDate = "air_date"
        }
    }

    private struct CachedSeason: Codable {
        let savedAt: Date
        let episodes: [SeasonEpisode]
    }

    /// Seasons TMDB does not have, for the session: asked once each.
    private var missingSeasons: Set<String> = []

    /// A show's season from TMDB, cached on disk as long as a title's detail.
    /// nil when TMDB has no such season or could not be reached.
    func seasonEpisodes(tvId: Int, season: Int) async -> [SeasonEpisode]? {
        let name = "tv_\(tvId)_season_\(season)"
        guard !missingSeasons.contains(name) else { return nil }
        let url = detailCacheDirectory.appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(CachedSeason.self, from: data),
           Date().timeIntervalSince(cached.savedAt) < detailCacheTTL {
            return cached.episodes
        }
        struct Response: Decodable { let episodes: [SeasonEpisode] }
        let data: Data
        do {
            data = try await fetchData(path: "tv/\(tvId)/season/\(season)")
        } catch {
            // An error answer (almost always "no such season") is remembered for
            // the session; a connection that failed asks again next time.
            if (error as? URLError)?.code == .badServerResponse { missingSeasons.insert(name) }
            return nil
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if let encoded = try? JSONEncoder().encode(CachedSeason(savedAt: Date(), episodes: response.episodes)) {
            try? encoded.write(to: url, options: [.atomic])
        }
        return response.episodes
    }

    // MARK: - Networking

    private func fetchData(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard let request = TMDBConfig.request(path: path, queryItems: queryItems) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await ForegroundGate.shared.data(for: request, in: session, always: true)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Disk Cache (List)

    private struct CachedList: Codable {
        let savedAt: Date
        let items: [TMDBListItem]
    }

    private func listCacheURL(name: String) -> URL {
        listCacheDirectory.appendingPathComponent("\(name).json")
    }

    private func loadListFromDisk(section: TMDBDiscoverSection, maxAge: TimeInterval) -> CachedList? {
        loadListFromDisk(name: section.rawValue, maxAge: maxAge)
    }

    private func loadListFromDisk(name: String, maxAge: TimeInterval) -> CachedList? {
        let url = listCacheURL(name: name)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedList.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < maxAge else { return nil }
        return cached
    }

    private func saveListToDisk(_ items: [TMDBListItem], section: TMDBDiscoverSection) {
        saveListToDisk(items, name: section.rawValue)
    }

    private func saveListToDisk(_ items: [TMDBListItem], name: String) {
        let cached = CachedList(savedAt: Date(), items: items)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: listCacheURL(name: name), options: [.atomic])
    }

    // MARK: - Disk Cache (Detail)

    private func detailCacheURL(tmdbId: Int, type: TMDBMediaType) -> URL {
        detailCacheDirectory.appendingPathComponent("\(type.rawValue)_\(tmdbId).json")
    }

    private struct CachedDetail: Codable {
        let savedAt: Date
        let version: Int
        let detail: TMDBItemDetail
    }

    private func loadDetailFromDisk(tmdbId: Int, type: TMDBMediaType) -> TMDBItemDetail? {
        let url = detailCacheURL(tmdbId: tmdbId, type: type)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedDetail.self, from: data),
              cached.version == Self.detailCacheVersion,
              Date().timeIntervalSince(cached.savedAt) < detailCacheTTL else { return nil }
        return cached.detail
    }

    private func saveDetailToDisk(_ detail: TMDBItemDetail, tmdbId: Int, type: TMDBMediaType) {
        let cached = CachedDetail(savedAt: Date(), version: Self.detailCacheVersion, detail: detail)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: detailCacheURL(tmdbId: tmdbId, type: type), options: [.atomic])
    }
}

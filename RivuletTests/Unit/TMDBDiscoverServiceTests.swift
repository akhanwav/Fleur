// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBDiscoverServiceTests.swift
//  RivuletTests

import XCTest
@testable import Rivulet

final class TMDBDiscoverServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(TMDBMockURLProtocol.self)
        TMDBMockURLProtocol.responses = [:]
        // Clear any stale disk caches from previous runs
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        for sub in ["TMDBDiscoverDetailCache", "TMDBDiscoverListCache"] {
            try? FileManager.default.removeItem(at: cachesDir.appendingPathComponent(sub, isDirectory: true))
        }
    }

    override func tearDown() {
        URLProtocol.unregisterClass(TMDBMockURLProtocol.self)
        super.tearDown()
    }

    func testFetchSectionDecodesPopularMovies() async {
        let json = """
        {
          "results": [
            {"id": 100, "title": "Test Movie", "poster_path": "/p.jpg", "backdrop_path": "/b.jpg", "release_date": "2024-01-01", "vote_average": 7.5, "overview": "..."}
          ]
        }
        """.data(using: .utf8)!

        TMDBMockURLProtocol.responses["3/movie/popular?"] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        let items = await service.fetchSection(.moviePopular)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, 100)
        XCTAssertEqual(items.first?.title, "Test Movie")
        XCTAssertEqual(items.first?.mediaType, .movie)
    }

    func testFetchSectionUsesTVTitleField() async {
        let json = """
        {
          "results": [
            {"id": 200, "name": "Test Show", "poster_path": "/p.jpg", "first_air_date": "2024-01-01"}
          ]
        }
        """.data(using: .utf8)!

        TMDBMockURLProtocol.responses["3/tv/popular?"] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        let items = await service.fetchSection(.tvPopular)

        XCTAssertEqual(items.first?.title, "Test Show")
        XCTAssertEqual(items.first?.releaseDate, "2024-01-01")
        XCTAssertEqual(items.first?.mediaType, .tv)
    }

    func testFetchSectionReturnsEmptyOnFailure() async {
        TMDBMockURLProtocol.responses["3/movie/popular?"] = (500, Data())
        let service = TMDBDiscoverService(session: makeMockSession())
        let items = await service.fetchSection(.moviePopular)
        XCTAssertTrue(items.isEmpty)
    }

    func testFetchSectionUsesInMemoryCache() async {
        let json = """
        {"results": [{"id": 1, "title": "A"}]}
        """.data(using: .utf8)!
        TMDBMockURLProtocol.responses["3/movie/popular?"] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        _ = await service.fetchSection(.moviePopular)

        // Second call: blank out the response. Cache should serve.
        TMDBMockURLProtocol.responses["3/movie/popular?"] = (500, Data())
        let second = await service.fetchSection(.moviePopular)
        XCTAssertEqual(second.first?.id, 1)
    }

    func testFetchDetailStampsTVMediaType() async {
        let json = """
        {"id": 300, "name": "Test Show", "genres": [], "cast": []}
        """.data(using: .utf8)!
        TMDBMockURLProtocol.responses[Self.detailKey("tv", 300)] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        let detail = await service.fetchDetail(tmdbId: 300, type: .tv)

        XCTAssertEqual(detail?.mediaType, .tv)
        XCTAssertEqual(detail?.title, "Test Show")
    }

    func testFetchDetailReturnsNilOnFailure() async {
        TMDBMockURLProtocol.responses[Self.detailKey("movie", 1)] = (404, Data())
        let service = TMDBDiscoverService(session: makeMockSession())
        let detail = await service.fetchDetail(tmdbId: 1, type: .movie)
        XCTAssertNil(detail)
    }

    func testFetchDetailDecodesCreditsRecommendationsAndWatchProviders() async {
        let json = """
        {
          "id": 400, "title": "Test Movie", "genres": [],
          "credits": {
            "cast": [{"id": 1, "name": "Cast One", "character": "Hero", "profile_path": "/p1.jpg"}],
            "crew": [{"id": 2, "name": "Director One", "job": "Director"}]
          },
          "recommendations": {"results": [{"id": 500, "title": "Similar Movie"}]},
          "watch/providers": {
            "results": {
              "US": {
                "link": "https://www.themoviedb.org/movie/400/watch",
                "flatrate": [{"provider_id": 8, "provider_name": "Netflix", "logo_path": "/n.jpg"}]
              }
            }
          }
        }
        """.data(using: .utf8)!
        TMDBMockURLProtocol.responses[Self.detailKey("movie", 400)] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        let detail = await service.fetchDetail(tmdbId: 400, type: .movie)

        XCTAssertEqual(detail?.cast.first?.name, "Cast One")
        XCTAssertEqual(detail?.crew.first?.job, "Director")
        XCTAssertEqual(detail?.recommendations.first?.id, 500)
        XCTAssertEqual(detail?.recommendations.first?.mediaType, .movie)
        XCTAssertEqual(detail?.watchProviders?.flatrate?.first?.providerName, "Netflix")
    }

    func testFetchDetailPicksOfficialYouTubeTrailer() async {
        let json = """
        {
          "id": 410, "title": "Test Movie", "genres": [],
          "videos": {
            "results": [
              {"key": "teaser1", "site": "YouTube", "type": "Teaser", "official": true, "name": "Teaser"},
              {"key": "trailer1", "site": "YouTube", "type": "Trailer", "official": false, "name": "Trailer (fan-sub)"},
              {"key": "trailer2", "site": "YouTube", "type": "Trailer", "official": true, "name": "Official Trailer"}
            ]
          }
        }
        """.data(using: .utf8)!
        TMDBMockURLProtocol.responses[Self.detailKey("movie", 410)] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        let detail = await service.fetchDetail(tmdbId: 410, type: .movie)

        XCTAssertEqual(detail?.youtubeTrailerKey, "trailer2")
    }

    /// A disk cache entry written before `append_to_response` grew a field
    /// (here: no `version` key at all, as any pre-this-change cache file on
    /// disk would be) must be treated as stale and refetched, never served
    /// as a silent hit missing that field.
    func testFetchDetailRefetchesWhenDiskCacheHasNoVersion() async {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDir = cachesDir.appendingPathComponent("TMDBDiscoverDetailCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let staleJSON = """
        {"savedAt": \(Date().timeIntervalSinceReferenceDate), "detail": {"id": 420, "title": "Stale", "genres": [], "media_type": "movie"}}
        """
        // Pre-dates the `version` field: write a raw dict missing that key.
        let staleData = staleJSON.data(using: .utf8)!
        try? staleData.write(to: cacheDir.appendingPathComponent("movie_420.json"))

        let json = """
        {"id": 420, "title": "Fresh", "genres": []}
        """.data(using: .utf8)!
        TMDBMockURLProtocol.responses[Self.detailKey("movie", 420)] = (200, json)

        let service = TMDBDiscoverService(session: makeMockSession())
        let detail = await service.fetchDetail(tmdbId: 420, type: .movie)

        XCTAssertEqual(detail?.title, "Fresh")
    }

    /// `fetchDetail` requests `append_to_response=credits,recommendations,watch/providers,videos`
    /// on every call (one round trip feeds Cast & Crew, More Like This, Where
    /// to Watch, and the Trailer button) — the mock key must include it to match.
    private static func detailKey(_ type: String, _ id: Int) -> String {
        "3/\(type)/\(id)?append_to_response=credits,recommendations,watch/providers,videos"
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TMDBMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class TMDBMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var hitCounts: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = "\(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))?\(url.query ?? "")"
        TMDBMockURLProtocol.hitCounts[key, default: 0] += 1
        let (status, data) = TMDBMockURLProtocol.responses[key] ?? (404, Data())
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

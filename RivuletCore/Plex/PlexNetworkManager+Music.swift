// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+Music.swift
//  Rivulet
//
//  Music-only endpoints: the genre directory, audio playlists and lyrics.
//

import Foundation

// MARK: - Response shapes

/// One row of `/library/sections/{id}/genre`. `key` is the id a `genre=` filter takes.
nonisolated struct PlexGenreDirectory: Decodable, Sendable {
    let key: String
    let title: String
}

nonisolated struct PlexGenreContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Directory: [PlexGenreDirectory]?
    }
    let MediaContainer: Container
}

/// A playlist row. Not `PlexMetadata`: playlists send `smart` as a JSON bool
/// and collections send it as "1", so one shared field cannot decode both.
nonisolated struct PlexPlaylist: Decodable, Sendable {
    let ratingKey: String
    let title: String?
    let composite: String?
    let leafCount: Int?
    let duration: Int?
    let smart: Bool?
}

nonisolated struct PlexPlaylistContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Metadata: [PlexPlaylist]?
    }
    let MediaContainer: Container
}

/// The server's parsed form of a lyric stream. Offsets are milliseconds;
/// an untimed line has no `startOffset`.
nonisolated struct PlexLyrics: Decodable, Sendable {
    nonisolated struct Line: Decodable, Sendable {
        nonisolated struct Span: Decodable, Sendable {
            let text: String?
        }
        let startOffset: Int?
        let Span: [Span]?
    }
    let Line: [Line]?
}

nonisolated struct PlexLyricsContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Lyrics: [PlexLyrics]?
    }
    let MediaContainer: Container
}

nonisolated struct PlexIdentityContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let machineIdentifier: String
    }
    let MediaContainer: Container
}

// MARK: - Requests

extension PlexNetworkManager {

    /// Genre directory of a section for one item type (8 artist, 9 album, 10 track).
    /// Without `type` the server answers with artist genres only.
    func getGenres(
        serverURL: String,
        authToken: String,
        sectionId: String,
        type: Int
    ) async throws -> [PlexGenreDirectory] {
        guard let url = URL(string: "\(serverURL)/library/sections/\(sectionId)/genre?type=\(type)") else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexGenreContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Directory ?? []
    }

    /// Audio playlists that hold tracks from one section.
    func getAudioPlaylists(
        serverURL: String,
        authToken: String,
        sectionId: String,
        sort: String
    ) async throws -> [PlexPlaylist] {
        guard let url = URL(string: "\(serverURL)/playlists?playlistType=audio&sectionID=\(sectionId)&sort=\(sort)") else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexPlaylistContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Metadata ?? []
    }

    /// One page of a playlist's tracks. A smart playlist can hold the whole library.
    func getPlaylistItemsWithTotal(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        start: Int,
        size: Int
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard let url = URL(string: "\(serverURL)/playlists/\(ratingKey)/items?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(size)") else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexMediaContainerWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return (container.MediaContainer.Metadata ?? [], container.MediaContainer.totalSize)
    }

    /// Append library items to a regular playlist. Unverified against a live server.
    func addToPlaylist(
        serverURL: String,
        authToken: String,
        playlistRatingKey: String,
        machineIdentifier: String,
        ratingKeys: [String]
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/playlists/\(playlistRatingKey)/items") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "uri", value: Self.libraryURI(machineIdentifier: machineIdentifier, ratingKeys: ratingKeys))
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        _ = try await requestData(url, method: "PUT", headers: plexHeaders(authToken: authToken))
    }

    /// The `uri` a playlist write takes. The host is the SERVER's machine identifier.
    nonisolated static func libraryURI(machineIdentifier: String, ratingKeys: [String]) -> String {
        "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKeys.joined(separator: ","))"
    }

    /// The server's own machine identifier, from `/identity`.
    func getMachineIdentifier(serverURL: String, authToken: String) async throws -> String {
        guard let url = URL(string: "\(serverURL)/identity") else { throw PlexAPIError.invalidURL }
        let container: PlexIdentityContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.machineIdentifier
    }

    /// A lyric stream as parsed lines, or nil when the server has no content for it.
    func getLyrics(serverURL: String, authToken: String, streamKey: String) async throws -> PlexLyrics? {
        guard let url = URL(string: "\(serverURL)\(streamKey)") else { throw PlexAPIError.invalidURL }
        var headers = plexHeaders(authToken: authToken)
        // Without it the server sends the raw file, and LyricFind streams send nothing.
        headers["Accept"] = "application/json"
        // requestData, not request: most LyricFind streams 404 and that is not worth a log line each.
        let data = try await requestData(url, headers: headers)
        return try Self.decodeRepairingUTF8(PlexLyricsContainer.self, from: data).MediaContainer.Lyrics?.first
    }
}

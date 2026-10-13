// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexMusicMapperTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PlexMusicMapperTests: XCTestCase {

    // MARK: - Artist

    func test_artist_maps_name_and_ref() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "artist"
        meta.title = "Radiohead"
        meta.thumb = "/library/metadata/100/thumb/123"

        let artist = PlexMusicMapper.artist(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(artist.name, "Radiohead")
        XCTAssertEqual(artist.ref.providerID, "plex:abc")
        XCTAssertEqual(artist.ref.itemID, "100")
        XCTAssertNotNil(artist.artwork.thumbnail)
    }

    func test_artist_user_state_from_userRating() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "artist"
        meta.title = "X"
        meta.userRating = 8          // Plex 0-10 scale
        meta.viewCount = 42

        let artist = PlexMusicMapper.artist(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertTrue(artist.userState.isFavorite)
        XCTAssertEqual(artist.userState.userRating, 4.0) // 8/2 normalized to 5-star
        XCTAssertEqual(artist.userState.playCount, 42)
    }

    func test_userState_unrated_is_not_favorite() {
        var meta = PlexMetadata()
        meta.ratingKey = "99"
        meta.type = "artist"
        meta.title = "Y"
        // userRating left nil

        let artist = PlexMusicMapper.artist(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertFalse(artist.userState.isFavorite)
        XCTAssertNil(artist.userState.userRating)
    }

    // MARK: - Album

    func test_album_maps_title_year_and_artist_link() {
        var meta = PlexMetadata()
        meta.ratingKey = "200"
        meta.type = "album"
        meta.title = "OK Computer"
        meta.parentRatingKey = "100"
        meta.parentTitle = "Radiohead"
        meta.year = 1997
        meta.leafCount = 12

        let album = PlexMusicMapper.album(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(album.title, "OK Computer")
        XCTAssertEqual(album.year, 1997)
        XCTAssertEqual(album.trackCount, 12)
        XCTAssertEqual(album.artistRef?.itemID, "100")
        XCTAssertEqual(album.artistName, "Radiohead")
    }

    // MARK: - Track

    func test_track_maps_number_duration_and_hierarchy() {
        var meta = PlexMetadata()
        meta.ratingKey = "300"
        meta.type = "track"
        meta.title = "Paranoid Android"
        meta.parentRatingKey = "200"
        meta.parentTitle = "OK Computer"
        meta.grandparentRatingKey = "100"
        meta.grandparentTitle = "Radiohead"
        meta.index = 2                   // track number
        meta.duration = 383_000          // ms

        let track = PlexMusicMapper.track(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(track.title, "Paranoid Android")
        XCTAssertEqual(track.trackNumber, 2)
        XCTAssertEqual(track.duration, 383.0)
        XCTAssertEqual(track.albumRef?.itemID, "200")
        XCTAssertEqual(track.albumTitle, "OK Computer")
        XCTAssertEqual(track.artistRef?.itemID, "100")
        XCTAssertEqual(track.artistName, "Radiohead")
    }

    func test_track_maps_discNumber_from_parentIndex() {
        var meta = PlexMetadata()
        meta.ratingKey = "301"
        meta.type = "track"
        meta.title = "Side B Track"
        meta.index = 1
        meta.parentIndex = 2          // disc 2
        meta.duration = 180_000

        let track = PlexMusicMapper.track(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(track.discNumber, 2)
    }

    func test_track_discNumber_nil_when_no_parentIndex() {
        var meta = PlexMetadata()
        meta.ratingKey = "302"
        meta.type = "track"
        meta.title = "Single-disc Track"
        meta.index = 3
        meta.duration = 200_000
        // parentIndex left unset

        let track = PlexMusicMapper.track(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertNil(track.discNumber)
    }

    // MARK: - MusicItem dispatch

    func test_item_dispatches_artist() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "artist"
        meta.title = "Radiohead"
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertEqual(item?.kind, .artist)
    }

    func test_item_dispatches_album() {
        var meta = PlexMetadata()
        meta.ratingKey = "200"
        meta.type = "album"
        meta.title = "X"
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertEqual(item?.kind, .album)
    }

    func test_item_dispatches_track() {
        var meta = PlexMetadata()
        meta.ratingKey = "300"
        meta.type = "track"
        meta.title = "X"
        meta.duration = 100
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertEqual(item?.kind, .track)
    }

    func test_item_returns_nil_for_non_music_type() {
        var meta = PlexMetadata()
        meta.ratingKey = "500"
        meta.type = "movie"
        meta.title = "X"
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertNil(item)
    }

    func test_track_artist_prefers_originalTitle_over_album_artist() {
        var meta = PlexMetadata()
        meta.ratingKey = "303"
        meta.type = "track"
        meta.grandparentTitle = "Original Broadway Cast"
        meta.originalTitle = "Leslie Odom Jr."

        let track = PlexMusicMapper.track(meta, providerID: "plex:abc", serverURL: "https://x", authToken: "T")
        XCTAssertEqual(track.artistName, "Leslie Odom Jr.")

        meta.originalTitle = ""
        let fallback = PlexMusicMapper.track(meta, providerID: "plex:abc", serverURL: "https://x", authToken: "T")
        XCTAssertEqual(fallback.artistName, "Original Broadway Cast")
    }

    // MARK: - Playlist

    func test_playlist_decodes_and_maps_smart_flag_and_composite() throws {
        let json = #"""
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"112685","title":"Hearts","smart":true,"composite":"/playlists/112685/composite/1","leafCount":772,"duration":164213000},
          {"ratingKey":"171461","title":"Disney Stories","smart":false,"leafCount":0}
        ]}}
        """#
        let rows = try JSONDecoder().decode(PlexPlaylistContainer.self, from: Data(json.utf8)).MediaContainer.Metadata ?? []
        let playlists = rows.map {
            PlexMusicMapper.playlist($0, providerID: "plex:abc", serverURL: "https://x", authToken: "T")
        }

        XCTAssertEqual(playlists.map(\.isSmart), [true, false])
        XCTAssertEqual(playlists[0].trackCount, 772)
        XCTAssertEqual(playlists[0].duration, 164_213)
        XCTAssertEqual(playlists[0].artworkURL?.absoluteString, "https://x/playlists/112685/composite/1?X-Plex-Token=T")
        XCTAssertNil(playlists[1].artworkURL)
        XCTAssertEqual(playlists[1].duration, 0)
    }

    func test_playlist_write_uri_names_the_server() {
        XCTAssertEqual(
            PlexNetworkManager.libraryURI(machineIdentifier: "srv", ratingKeys: ["1", "2"]),
            "server://srv/com.plexapp.plugins.library/library/metadata/1,2"
        )
    }

    // MARK: - Lyrics

    private func lyrics(_ json: String) throws -> PlexLyrics? {
        try JSONDecoder().decode(PlexLyricsContainer.self, from: Data(json.utf8)).MediaContainer.Lyrics?.first
    }

    func test_lyricLines_trims_carriage_returns_and_drops_blank_lines() throws {
        let parsed = try XCTUnwrap(lyrics(#"""
        {"MediaContainer":{"size":1,"Lyrics":[{"timed":true,"Line":[
          {"startOffset":7940,"endOffset":12690,"Span":[{"text":"First line\r","startOffset":7940}]},
          {"startOffset":41420,"Span":[{"text":"\r"}]},
          {"startOffset":41420},
          {"startOffset":229850,"Span":[{"text":"Two "},{"text":"spans"}]}
        ]}]}}
        """#))

        XCTAssertEqual(PlexMusicMapper.lyricLines(parsed), [
            MusicLyricLine(start: 7.94, text: "First line"),
            MusicLyricLine(start: 229.85, text: "Two spans"),
        ])
    }

    func test_lyricLines_nil_for_untimed_and_for_empty_lyrics() throws {
        let untimed = try XCTUnwrap(lyrics(#"{"MediaContainer":{"Lyrics":[{"Line":[{"Span":[{"text":"No clock"}]}]}]}}"#))
        XCTAssertNil(PlexMusicMapper.lyricLines(untimed))

        // What a LyricFind stream answers when it has nothing.
        let empty = try XCTUnwrap(lyrics(#"{"MediaContainer":{"size":1,"Lyrics":[{}]}}"#))
        XCTAssertNil(PlexMusicMapper.lyricLines(empty))
    }

    func test_lyricStreamKeys_keeps_only_lrc_lyric_streams() throws {
        let json = #"""
        {"ratingKey":"1","type":"track","Media":[{"id":1,"Part":[{"id":2,"Stream":[
          {"id":10,"streamType":2,"codec":"flac"},
          {"id":11,"streamType":4,"codec":"lrc","key":"/library/streams/11"},
          {"id":12,"streamType":4,"codec":"txt","key":"/library/streams/12"}
        ]}]}]}
        """#
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(PlexMusicMapper.lyricStreamKeys(meta), ["/library/streams/11"])
    }

    func test_activeIndex_is_the_last_line_that_has_started() {
        let lines = [MusicLyricLine(start: 5, text: "a"), MusicLyricLine(start: 10, text: "b")]
        XCTAssertNil(lines.activeIndex(at: 4.9))
        XCTAssertEqual(lines.activeIndex(at: 5), 0)
        XCTAssertEqual(lines.activeIndex(at: 99), 1)
    }

    func test_activeIndex_with_a_lead_brings_a_line_in_early() {
        let lines = [MusicLyricLine(start: 5, text: "a"), MusicLyricLine(start: 10, text: "b")]
        let lead = MusicLyricLine.lead
        XCTAssertEqual(lead, 0.75)
        XCTAssertNil(lines.activeIndex(at: 4.24, lead: lead))
        XCTAssertEqual(lines.activeIndex(at: 4.25, lead: lead), 0)
        XCTAssertEqual(lines.activeIndex(at: 9.24, lead: lead), 0)
        XCTAssertEqual(lines.activeIndex(at: 9.25, lead: lead), 1)
        XCTAssertNil([MusicLyricLine]().activeIndex(at: 3, lead: lead))
    }

    // MARK: - Sort and filter

    func test_sortString_uses_the_server_album_artist_sort_per_type() {
        XCTAssertEqual(PlexMusicProvider.sortString(.title, type: 9), "titleSort:asc")
        XCTAssertEqual(PlexMusicProvider.sortString(.artist, type: 8), "titleSort:asc")
        XCTAssertTrue(PlexMusicProvider.sortString(.artist, type: 9).hasPrefix("artist.titleSort,album.titleSort"))
        XCTAssertTrue(PlexMusicProvider.sortString(.artist, type: 10).contains("track.index"))
        XCTAssertEqual(PlexMusicProvider.sortString(.recentlyAdded, type: 10), "addedAt:desc")
        XCTAssertEqual(PlexMusicProvider.sortString(.random, type: 10), "random")
        // Keys confirmed against PMS 1.43.4 with read-only requests.
        XCTAssertEqual(PlexMusicProvider.sortString(.year, type: 9), "year:desc,titleSort")
        XCTAssertTrue(PlexMusicProvider.sortString(.year, type: 10).hasPrefix("album.year:desc,album.titleSort"))
        XCTAssertTrue(PlexMusicProvider.sortString(.album, type: 10).hasPrefix("album.titleSort,album.year,track.absoluteIndex"))
        XCTAssertEqual(PlexMusicProvider.sortString(.album, type: 9), "titleSort:asc")
        XCTAssertEqual(PlexMusicProvider.sortString(.recentlyAdded, type: 8), "addedAt:desc")
        XCTAssertEqual(PlexMusicProvider.sortString(.title, type: 15), "titleSort:asc")
        XCTAssertEqual(PlexMusicProvider.sortString(.recentlyAdded, type: 15), "addedAt:desc")
        // Header Play behind a list by date added: each album whole, in track order.
        XCTAssertEqual(
            PlexMusicProvider.sortString(.albumRecentlyAdded, type: 10),
            "album.addedAt:desc,album.id,track.absoluteIndex,track.index,track.titleSort,track.id")
        XCTAssertEqual(
            PlexMusicProvider.sortString(.artistRecentlyAdded, type: 10),
            "artist.addedAt:desc,artist.id,album.titleSort,album.year,"
                + "track.absoluteIndex,track.index,track.titleSort,track.id")
    }

    func test_filterItems_genre_key_depends_on_type_and_favorites_match_the_threshold() {
        let filter = MusicFilter(genreID: "108336", favoritesOnly: true)

        XCTAssertEqual(PlexMusicProvider.filterItems(filter, type: 9), [
            URLQueryItem(name: "genre", value: "108336"),
            URLQueryItem(name: "userRating>>", value: "6"),
        ])
        XCTAssertEqual(PlexMusicProvider.filterItems(filter, type: 10).first?.name, "album.genre")
        XCTAssertTrue(PlexMusicProvider.filterItems(MusicFilter(), type: 9).isEmpty)
        // The boundary the server filter and the star must agree on.
        XCTAssertFalse(PlexUserRating.isFavorite(6))
        XCTAssertTrue(PlexUserRating.isFavorite(7))
    }
}

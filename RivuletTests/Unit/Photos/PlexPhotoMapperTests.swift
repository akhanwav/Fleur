// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Fixtures follow the documented response shapes, not a captured photo section.
final class PlexPhotoMapperTests: XCTestCase {
    private func map(_ json: String) throws -> PhotoItem? {
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        return PlexPhotoMapper.item(meta, providerID: "plex:abc", serverURL: "http://s:32400", authToken: "tok")
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func test_album_isToldByItsKey_notItsType() throws {
        let album = try XCTUnwrap(map(#"""
        {"ratingKey":"10","key":"/library/metadata/10/children","type":"photo","title":"Italy",
         "thumb":"/library/metadata/10/thumb/1","leafCount":128,"addedAt":1700000000}
        """#))
        XCTAssertEqual(album.kind, .folder)
        XCTAssertEqual(album.ref, MediaItemRef(providerID: "plex:abc", itemID: "10"))
        XCTAssertEqual(album.title, "Italy")
        XCTAssertEqual(album.childCount, 128)
        XCTAssertNil(album.full, "a folder is never shown full screen")
        XCTAssertNil(album.playable)
    }

    func test_photo_datesAndSizedURLs() throws {
        let photo = try XCTUnwrap(map(#"""
        {"ratingKey":"11","key":"/library/metadata/11","type":"photo","title":"IMG_0001",
         "thumb":"/library/metadata/11/thumb/1","originallyAvailableAt":"2024-06-09","addedAt":1700000000,
         "Media":[{"id":1,"width":4032,"height":3024,"Part":[{"id":2,"key":"/library/parts/2/1/IMG_0001.heic"}]}]}
        """#))
        XCTAssertEqual(photo.kind, .photo)
        XCTAssertNil(photo.childCount)
        XCTAssertNil(photo.playable)
        let taken = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: try XCTUnwrap(photo.date))
        XCTAssertEqual([taken.year, taken.month, taken.day], [2024, 6, 9], "the date taken, not the scan time")

        let thumb = query(photo.thumbnail)
        XCTAssertEqual(photo.thumbnail?.path, "/photo/:/transcode")
        XCTAssertEqual(thumb["url"], "/library/metadata/11/thumb/1")
        XCTAssertEqual([thumb["width"], thumb["height"]], ["520", "520"])
        XCTAssertEqual(thumb["minSize"], "1", "a tile is a cover")
        XCTAssertEqual(thumb["upscale"], "0")
        XCTAssertEqual(thumb["X-Plex-Token"], "tok")

        let full = query(photo.full)
        XCTAssertEqual(full["url"], "/library/parts/2/1/IMG_0001.heic", "the file, through the transcoder")
        XCTAssertEqual([full["width"], full["height"]], ["3840", "2160"])
        XCTAssertNil(full["minSize"], "with minSize a portrait photo comes back screen-wide")
        XCTAssertEqual(photo.full?.path, "/photo/:/transcode", "the original file is never requested directly")
    }

    func test_photo_withoutDateTaken_fallsBackToAddedAt_andThumb() throws {
        let photo = try XCTUnwrap(map(#"""
        {"ratingKey":"12","key":"/library/metadata/12","type":"photo","title":"scan",
         "thumb":"/library/metadata/12/thumb/1","addedAt":1700000000}
        """#))
        XCTAssertEqual(photo.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(query(photo.full)["url"], "/library/metadata/12/thumb/1")
    }

    func test_clip_carriesAPlayableItem_andAStillForItsImage() throws {
        let clip = try XCTUnwrap(map(#"""
        {"ratingKey":"13","key":"/library/metadata/13","type":"clip","title":"MOV_0002","duration":12000,
         "thumb":"/library/metadata/13/thumb/1",
         "Media":[{"id":3,"Part":[{"id":4,"key":"/library/parts/4/1/MOV_0002.mov"}]}]}
        """#))
        XCTAssertEqual(clip.kind, .clip)
        XCTAssertEqual(clip.playable?.ref, clip.ref)
        XCTAssertEqual(query(clip.full)["url"], "/library/metadata/13/thumb/1", "never the video file")
    }

    func test_otherTypes_andItemsWithoutAKey_areDropped() throws {
        XCTAssertNil(try map(#"{"ratingKey":"14","key":"/library/metadata/14","type":"movie","title":"x"}"#))
        XCTAssertNil(try map(#"{"key":"/library/metadata/15","type":"photo","title":"x"}"#))
    }
}

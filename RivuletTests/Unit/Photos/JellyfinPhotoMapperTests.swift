// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Fixtures follow the documented response shapes, not a captured library.
@MainActor
final class JellyfinPhotoMapperTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let library = MediaLibrary(id: "lib", providerID: "jellyfin:srv", title: "Photos", kind: .photos)

    private func provider() -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                         client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                transport: server.transport))
    }

    private func map(_ json: String) -> PhotoItem? {
        JellyfinPhotoMapper.item(JellyfinFixtures.decode(json), providerID: "jellyfin:srv",
                                 baseURL: JellyfinFixtures.baseURL)
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func test_kinds_andUnknownTypesDropped() {
        XCTAssertEqual(map(#"{"Id":"a","Name":"Italy","Type":"PhotoAlbum","RecursiveItemCount":12}"#)?.kind, .folder)
        XCTAssertEqual(map(#"{"Id":"a","Name":"Italy","Type":"PhotoAlbum","RecursiveItemCount":12}"#)?.childCount, 12)
        XCTAssertEqual(map(#"{"Id":"b","Name":"2024","Type":"Folder"}"#)?.kind, .folder)
        XCTAssertEqual(map(#"{"Id":"c","Name":"IMG","Type":"Photo"}"#)?.kind, .photo)
        XCTAssertNil(map(#"{"Id":"d","Name":"Song","Type":"Audio"}"#))
        XCTAssertNil(map(#"{"Name":"no id","Type":"Photo"}"#))
    }

    func test_photo_sizedURLs() {
        let photo = map(#"{"Id":"c","Name":"IMG","Type":"Photo","ImageTags":{"Primary":"tag1"}}"#)
        XCTAssertEqual(photo?.thumbnail?.path, "/Items/c/Images/Primary")
        let thumb = query(photo?.thumbnail)
        XCTAssertEqual([thumb["tag"], thumb["fillWidth"], thumb["fillHeight"]], ["tag1", "520", "520"])
        let full = query(photo?.full)
        XCTAssertEqual([full["maxWidth"], full["maxHeight"]], ["3840", "2160"])
        XCTAssertNil(full["fillWidth"], "full screen is a fit, not a cover")
        XCTAssertNil(photo?.playable)
    }

    func test_date_prefersPremiereDate_thenDateCreated() {
        let taken = map(#"{"Id":"c","Type":"Photo","PremiereDate":"2024-06-09T10:00:00.0000000Z","DateCreated":"2025-01-01T00:00:00.0000000Z"}"#)
        XCTAssertEqual(taken?.date, JellyfinMediaMapper.parseDate("2024-06-09T10:00:00.0000000Z"))
        let filed = map(#"{"Id":"c","Type":"Photo","DateCreated":"2025-01-01T00:00:00.0000000Z"}"#)
        XCTAssertEqual(filed?.date, JellyfinMediaMapper.parseDate("2025-01-01T00:00:00.0000000Z"))
        XCTAssertNotNil(filed?.date)
    }

    func test_video_isAClip_withAPlayableItem() {
        let clip = map(#"{"Id":"v","Name":"MOV","Type":"Video","ImageTags":{"Primary":"t"}}"#)
        XCTAssertEqual(clip?.kind, .clip)
        XCTAssertEqual(clip?.playable?.ref, MediaItemRef(providerID: "jellyfin:srv", itemID: "v"))
    }

    func test_homeVideosLibrary_isAPhotoLibrary() {
        let view: JFItem = JellyfinFixtures.decode(#"{"Id":"h","Name":"Home","CollectionType":"homevideos"}"#)
        XCTAssertEqual(JellyfinMediaMapper.library(view, providerID: "jellyfin:srv")?.kind, .photos)
    }

    // MARK: - Requests

    func test_root_asksFoldersOnce_andEveryPhotoRecursively() async throws {
        server.respond("/Items", query: ["includeItemTypes": "PhotoAlbum,Folder"],
                       body: #"{"Items":[{"Id":"a","Name":"Italy","Type":"PhotoAlbum"}],"TotalRecordCount":1}"#)
        server.respond("/Items", query: ["includeItemTypes": "Photo,Video"],
                       body: #"{"Items":[{"Id":"c","Type":"Photo"},{"Id":"v","Type":"Video"}],"TotalRecordCount":450}"#)

        let page = try await provider().photoPage(in: library, folder: nil, page: Page(offset: 0, limit: 200))

        XCTAssertEqual(page.folders.map(\.ref.itemID), ["a"])
        XCTAssertEqual(page.media.map(\.kind), [.photo, .clip])
        XCTAssertEqual(page.nextPage, Page(offset: 200, limit: 200))
        let media = server.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
            .map { Dictionary(uniqueKeysWithValues: $0.map { ($0.name, $0.value ?? "") }) }
            .first { $0["includeItemTypes"] == "Photo,Video" }
        XCTAssertEqual(media?["parentId"], "lib")
        XCTAssertEqual(media?["recursive"], "true")
        XCTAssertEqual(media?["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(media?["sortOrder"], "Descending")
        XCTAssertEqual([media?["startIndex"], media?["limit"]], ["0", "200"])
    }

    func test_folder_laterPage_asksOnlyItsOwnMedia() async throws {
        server.respond("/Items", query: ["includeItemTypes": "Photo,Video"],
                       body: #"{"Items":[{"Id":"c","Type":"Photo"}],"TotalRecordCount":201}"#)

        let page = try await provider().photoPage(
            in: library, folder: MediaItemRef(providerID: "jellyfin:srv", itemID: "a"),
            page: Page(offset: 200, limit: 200))

        XCTAssertNil(page.nextPage)
        XCTAssertEqual(server.requests.count, 1, "folders come with the first page only")
        let query = Dictionary(uniqueKeysWithValues: server.query(0).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["parentId"], "a")
        XCTAssertNil(query["recursive"], "a folder lists its own photos")
    }
}

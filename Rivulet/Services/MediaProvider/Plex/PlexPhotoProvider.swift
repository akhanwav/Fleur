// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPhotoProvider.swift
//  Rivulet
//
//  Plex photo sections. Every assumption about how PMS answers for one lives
//  in this file. None of it has been seen against a live photo section.
//

import Foundation

enum PlexPhotoMapper {
    /// An album is told from a photo by its key alone: both are `type="photo"`.
    static func item(_ meta: PlexMetadata, providerID: String, serverURL: String, authToken: String) -> PhotoItem? {
        guard let ratingKey = meta.ratingKey else { return nil }
        let kind: PhotoItem.Kind
        if meta.key?.hasSuffix("/children") == true {
            kind = .folder
        } else if meta.type == "clip" {
            kind = .clip
        } else if meta.type == "photo" {
            kind = .photo
        } else {
            return nil
        }
        func image(_ path: String?, cover: Bool) -> URL? {
            imageURL(path, serverURL: serverURL, authToken: authToken, cover: cover)
        }
        // A clip's Part is the video file, so its still is the thumb.
        let original = kind == .photo ? meta.Media?.first?.Part?.first?.key : nil
        return PhotoItem(
            ref: MediaItemRef(providerID: providerID, itemID: ratingKey),
            kind: kind,
            title: meta.title ?? "",
            date: date(meta),
            childCount: kind == .folder ? (meta.leafCount ?? meta.childCount) : nil,
            thumbnail: image(meta.thumb, cover: true),
            full: kind == .folder ? nil : image(original ?? meta.thumb, cover: false),
            playable: kind == .clip
                ? PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: authToken)
                : nil)
    }

    /// Date taken (`originallyAvailableAt`), else when it was scanned.
    static func date(_ meta: PlexMetadata) -> Date? {
        if let taken = meta.originallyAvailableAt,
           let date = try? Date(taken, strategy: .iso8601.year().month().day()) {
            return date
        }
        return meta.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// The server's image transcoder. `cover` fills a square tile; without it
    /// the image fits inside the screen. A fit must not send `minSize=1`: with
    /// it a portrait photo comes back screen-wide and several times the bytes.
    static func imageURL(_ path: String?, serverURL: String, authToken: String, cover: Bool) -> URL? {
        guard let path, !path.isEmpty, var components = URLComponents(string: "\(serverURL)/photo/:/transcode") else {
            return nil
        }
        let side = PhotoItem.thumbnailSide
        let (width, height) = cover ? (side, side) : PhotoItem.fullSize
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "upscale", value: "0")
        ] + (cover ? [URLQueryItem(name: "minSize", value: "1")] : [])
          + [URLQueryItem(name: "X-Plex-Token", value: authToken)]
        return components.url
    }
}

extension PlexProvider: PhotoProvider {
    private static let photoSort = "originallyAvailableAt:desc"

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> PhotoPage {
        #if DEBUG
        if library.id == PlexPhotoFixture.key {
            return try await PlexPhotoFixture.page(self, folder: folder, page: page)
        }
        #endif
        return try await plexCall {
            func map(_ metas: [PlexMetadata]) -> [PhotoItem] {
                metas.compactMap {
                    PlexPhotoMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
                }
            }
            let next = Page(offset: page.offset + page.limit, limit: page.limit)

            // A folder: sub-albums, photos and clips come back in one list.
            if let folder {
                let children = try await networkManager.getChildren(
                    serverURL: serverURL, authToken: authToken, ratingKey: folder.itemID,
                    start: page.offset, size: page.limit, sort: Self.photoSort)
                let items = map(children)
                return PhotoPage(folders: items.filter { $0.kind == .folder },
                                 media: items.filter { $0.kind != .folder },
                                 nextPage: children.count >= page.limit ? next : nil)
            }

            // The root: top-level albums (type 14) once, then every photo and clip (types 13, 12).
            // ponytail: one request of 1000 albums; page it if a section ever has more.
            func albums() async throws -> [PlexMetadata] {
                guard page.offset == 0 else { return [] }
                return try await networkManager.getLibraryItemsWithTotal(
                    serverURL: serverURL, authToken: authToken, sectionId: library.id,
                    size: 1000, sort: "titleSort", type: 14).items
            }
            async let albumList = albums()
            let photos = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken, sectionId: library.id,
                start: page.offset, size: page.limit, sort: Self.photoSort,
                filters: [URLQueryItem(name: "type", value: "13,12")])
            let more = next.offset < (photos.totalSize ?? 0)
            return PhotoPage(folders: map(try await albumList).filter { $0.kind == .folder },
                             media: map(photos.items).filter { $0.kind != .folder },
                             nextPage: more ? next : nil)
        }
    }
}

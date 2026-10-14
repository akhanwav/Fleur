// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinPhotoProvider.swift
//  Rivulet
//
//  Jellyfin "Home Videos and Photos" libraries. Every assumption about how
//  the server answers for one lives in this file. None of it has been seen
//  against a live library.
//

import Foundation

enum JellyfinPhotoMapper {
    static func item(_ dto: JFItem, providerID: String, baseURL: URL) -> PhotoItem? {
        guard let id = dto.id else { return nil }
        let kind: PhotoItem.Kind
        switch dto.type {
        case "PhotoAlbum", "Folder": kind = .folder
        case "Photo": kind = .photo
        case "Video": kind = .clip
        default: return nil
        }
        let side = "\(PhotoItem.thumbnailSide)"
        let (width, height) = PhotoItem.fullSize
        func image(_ size: [URLQueryItem]) -> URL? {
            guard let url = JellyfinMediaMapper.imageURL(baseURL, itemID: id, type: "Primary",
                                                         tag: dto.imageTags?["Primary"]) else { return nil }
            return url.appending(queryItems: size + [URLQueryItem(name: "quality", value: "90")])
        }
        return PhotoItem(
            ref: MediaItemRef(providerID: providerID, itemID: id),
            kind: kind,
            title: dto.name ?? "",
            // The EXIF date lands in both; a file without one has only DateCreated.
            date: (dto.premiereDate ?? dto.dateCreated).flatMap(JellyfinMediaMapper.parseDate),
            childCount: kind == .folder ? dto.recursiveItemCount : nil,
            thumbnail: image([URLQueryItem(name: "fillWidth", value: side),
                              URLQueryItem(name: "fillHeight", value: side)]),
            full: kind == .folder ? nil : image([URLQueryItem(name: "maxWidth", value: "\(width)"),
                                                 URLQueryItem(name: "maxHeight", value: "\(height)")]),
            playable: kind == .clip
                ? JellyfinMediaMapper.item(dto, providerID: providerID, baseURL: baseURL)
                : nil)
    }
}

extension JellyfinProvider: PhotoProvider {
    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> PhotoPage {
        let parent = URLQueryItem(name: "parentId", value: folder?.itemID ?? library.id)
        let fields = URLQueryItem(name: "fields", value: "DateCreated,RecursiveItemCount")
        func map(_ result: JFQueryResult?) -> [PhotoItem] {
            (result?.items ?? []).compactMap {
                JellyfinPhotoMapper.item($0, providerID: id, baseURL: client.baseURL)
            }
        }

        // Folders are direct children, asked for once.
        func folders() async throws -> JFQueryResult? {
            guard page.offset == 0 else { return nil }
            return try await client.get("Items", [
                parent, fields,
                URLQueryItem(name: "includeItemTypes", value: "PhotoAlbum,Folder"),
                URLQueryItem(name: "sortBy", value: "SortName")
            ])
        }
        async let folderList = folders()
        // The root lists every photo in the library; a folder lists its own.
        let media: JFQueryResult = try await client.get("Items", [
            parent, fields,
            URLQueryItem(name: "includeItemTypes", value: "Photo,Video"),
            URLQueryItem(name: "sortBy", value: "DateCreated,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
            URLQueryItem(name: "startIndex", value: "\(page.offset)"),
            URLQueryItem(name: "limit", value: "\(page.limit)"),
            URLQueryItem(name: "enableTotalRecordCount", value: "true")
        ] + (folder == nil ? [URLQueryItem(name: "recursive", value: "true")] : []))
        let next = Page(offset: page.offset + page.limit, limit: page.limit)
        return PhotoPage(folders: map(try await folderList).filter { $0.kind == .folder },
                         media: map(media).filter { $0.kind != .folder },
                         nextPage: next.offset < (media.totalRecordCount ?? 0) ? next : nil)
    }
}

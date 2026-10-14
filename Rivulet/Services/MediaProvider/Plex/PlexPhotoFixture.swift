// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPhotoFixture.swift
//  Rivulet
//
//  DEBUG only. Stands a video library's artwork in as a photo library, so the
//  photo surfaces can be driven on a server that has no photo section:
//  RIVULET_PHOTO_FIXTURE=<video library title>. Read-only against the server.
//

#if DEBUG
import Foundation

enum PlexPhotoFixture {
    static let key = "photo-fixture"
    private static let sourceTitle = ProcessInfo.processInfo.environment["RIVULET_PHOTO_FIXTURE"]

    /// The stand-in section, once the real ones are known and it is not among them.
    static func section(missingFrom libraries: [PlexLibrary]) -> PlexLibrary? {
        guard sourceTitle != nil, !libraries.isEmpty, !libraries.contains(where: { $0.key == key }) else { return nil }
        return PlexLibrary(key: key, type: "photo", title: "Photos", agent: nil, scanner: nil,
                           language: nil, uuid: key, updatedAt: nil, createdAt: nil,
                           scannedAt: nil, Location: nil)
    }

    /// Root: three folders, then every title of the source library, paged.
    /// A folder: 30 titles from further in, and the first holds a sub-folder.
    static func page(_ provider: PlexProvider, folder: MediaItemRef?, page: Page) async throws -> PhotoPage {
        let sections = try await provider.networkManager.getLibraries(
            serverURL: provider.serverURL, authToken: provider.authToken)
        guard let section = sections.first(where: { $0.title == sourceTitle }) else {
            throw MediaProviderError.notFound
        }
        let depth = folder.map { $0.itemID.split(separator: "-").count - 1 } ?? 0
        let result = try await provider.networkManager.getLibraryItemsWithTotal(
            serverURL: provider.serverURL, authToken: provider.authToken, sectionId: section.key,
            start: folder == nil ? page.offset : 20 + (folder?.itemID.count ?? 0) * 10,
            size: folder == nil ? page.limit : 30, sort: "addedAt:desc")
        func image(_ path: String?, cover: Bool) -> URL? {
            PlexPhotoMapper.imageURL(path, serverURL: provider.serverURL, authToken: provider.authToken, cover: cover)
        }
        // The root's second tile poses as a clip (badge and glyph only: it has nothing to play).
        let media = result.items.enumerated().map { index, meta in
            PhotoItem(ref: MediaItemRef(providerID: provider.id,
                                        itemID: "\(folder?.itemID ?? "root")/\(meta.ratingKey ?? "")"),
                      kind: folder == nil && page.offset == 0 && index == 1 ? .clip : .photo, title: meta.title ?? "", date: PlexPhotoMapper.date(meta), childCount: nil,
                      thumbnail: image(meta.thumb, cover: true), full: image(meta.art ?? meta.thumb, cover: false),
                      playable: nil)
        }
        let names = folder == nil ? ["a", "b", "c"] : (depth == 1 && folder?.itemID.hasSuffix("a") == true ? ["x"] : [])
        let folders = page.offset > 0 ? [] : names.enumerated().map { index, name in
            PhotoItem(ref: MediaItemRef(providerID: provider.id, itemID: "\(folder?.itemID ?? "f")-\(name)"),
                      kind: .folder, title: "Folder \(name.uppercased())", date: nil, childCount: 30,
                      thumbnail: media.indices.contains(index) ? media[index].thumbnail : nil,
                      full: nil, playable: nil)
        }
        let next = Page(offset: page.offset + page.limit, limit: page.limit)
        let more = folder == nil && next.offset < (result.totalSize ?? 0)
        return PhotoPage(folders: folders, media: media, nextPage: more ? next : nil)
    }
}
#endif

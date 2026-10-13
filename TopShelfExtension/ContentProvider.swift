// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentProvider.swift
//  TopShelfExtension
//
//  TV Services Extension for Top Shelf content — Apple TV+-style carousel.
//

import TVServices
import os.log

private let logger = Logger(subsystem: "com.gstudios.rivulet.TopShelfExtension", category: "ContentProvider")

class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        let items = TopShelfCache.shared.readItems()
        logger.info("TopShelf: Read \(items.count) items from cache")

        guard !items.isEmpty else {
            logger.warning("TopShelf: No items to display, returning nil")
            return nil
        }

        let carouselItems = items.compactMap { item -> TVTopShelfCarouselItem? in
            let cItem = TVTopShelfCarouselItem(identifier: item.ratingKey)

            // `title` (inherited from TVTopShelfObject) is the carousel's main
            // heading — the movie/episode name. `contextTitle` is the small line
            // above it; we use it for the show name on episodes. Map:
            //   episode -> title = episode name, contextTitle = show name
            //   movie   -> title = movie name,   contextTitle = nil
            cItem.title = item.title
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                cItem.contextTitle = subtitle   // show name (episodes)
            }

            // Prefer the in-app composite (backdrop + logo) file when present.
            // Fall back to the network backdrop so an item is NEVER dropped.
            if let fileName = item.compositeFileName,
               let fileURL = TopShelfCache.shared.compositeFileURL(fileName: fileName),
               FileManager.default.fileExists(atPath: fileURL.path) {
                cItem.setImageURL(fileURL, for: .screenScale1x)
                cItem.setImageURL(fileURL, for: .screenScale2x)
            } else {
                // 16:9 backdrop art; fall back to the poster so an item is NEVER dropped.
                let art = item.wideImageURL.isEmpty ? item.imageURL : item.wideImageURL
                if let url = URL(string: art) {
                    cItem.setImageURL(url, for: .screenScale1x)
                    cItem.setImageURL(url, for: .screenScale2x)
                }
            }

            // Play resumes the item; Select / More Info opens its detail.
            guard let playURL = RivuletLink(.play, ratingKey: item.ratingKey, server: item.serverIdentifier).url,
                  let detailURL = RivuletLink(.detail, ratingKey: item.ratingKey, server: item.serverIdentifier).url
            else { return nil }
            cItem.playAction = TVTopShelfAction(url: playURL)
            cItem.displayAction = TVTopShelfAction(url: detailURL)

            return cItem
        }

        guard !carouselItems.isEmpty else {
            logger.warning("TopShelf: No valid items after mapping, returning nil")
            return nil
        }

        logger.info("TopShelf: Returning \(carouselItems.count) carousel items")
        return TVTopShelfCarouselContent(style: .details, items: carouselItems)
    }
}

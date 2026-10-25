// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ArtworkFallback.swift
//  Rivulet
//
//  TMDB artwork for a server item whose own is missing or wrong. Plex hands
//  out exactly what the server stored: an item no agent matched has a frame
//  of the video as its "poster" and often no background art at all, so the
//  app has nothing better to ask that server for. Callers decide when the
//  server's art is wrong (a landscape image in a poster slot, no backdrop, a
//  backdrop far below screen size, a backdrop that is a frame of the video);
//  this finds the title on TMDB and returns its poster (w780) and backdrop
//  (original size). Cached for the session.
//

import Foundation
import UIKit

actor ArtworkFallback {
    static let shared = ArtworkFallback()

    /// What a lookup knows about the title.
    struct Query: Hashable, Sendable {
        let tmdbId: Int?
        let isMovie: Bool
        let title: String
        let year: Int?
    }

    private static let posterBase = "https://image.tmdb.org/t/p/w780"
    private static let backdropBase = "https://image.tmdb.org/t/p/original"

    private var cache: [Query: TMDBArtworkPaths?] = [:]
    private var inFlight: [Query: Task<TMDBArtworkPaths?, Never>] = [:]

    func poster(for query: Query) async -> URL? {
        await paths(for: query)?.posterPath.flatMap { URL(string: Self.posterBase + $0) }
    }

    func backdrop(for query: Query) async -> URL? {
        await paths(for: query)?.backdropPath.flatMap { URL(string: Self.backdropBase + $0) }
    }

    private func paths(for query: Query) async -> TMDBArtworkPaths? {
        if let cached = cache[query] { return cached }
        if let task = inFlight[query] { return await task.value }
        let task = Task {
            await TMDBClient.shared.artworkPaths(tmdbId: query.tmdbId, type: query.isMovie ? .movie : .tv,
                                                 title: query.title, year: query.year)
        }
        inFlight[query] = task
        let result = await task.value
        inFlight[query] = nil
        cache[query] = result
        return result
    }
}

extension ArtworkFallback.Query {
    /// The title a Plex item's poster or backdrop belongs to: an episode's or
    /// season's is its show's. nil for music, people and other non-video.
    init?(_ meta: PlexMetadata) {
        switch meta.type {
        case "movie":
            guard let title = meta.title else { return nil }
            self.init(tmdbId: meta.tmdbId, isMovie: true, title: title, year: meta.year)
        case "show":
            guard let title = meta.title else { return nil }
            self.init(tmdbId: meta.tmdbId, isMovie: false, title: title, year: meta.year)
        case "episode", "season":
            guard let title = meta.grandparentTitle ?? meta.parentTitle else { return nil }
            self.init(tmdbId: nil, isMovie: false, title: title, year: nil)
        default:
            return nil
        }
    }

    /// A MediaItem's: movies and shows only (an episode tile shows its
    /// show's poster, which the show's own page falls back for).
    init?(_ item: MediaItem) {
        switch item.kind {
        case .movie: self.init(tmdbId: item.tmdbID, isMovie: true, title: item.title, year: item.year)
        case .show: self.init(tmdbId: item.tmdbID, isMovie: false, title: item.title, year: item.year)
        default: return nil
        }
    }
}

extension ArtworkFallback {
    /// Whether a server background should give way to TMDB's: missing, too
    /// small for the screen (under 1280 px it is a stretched thumbnail on a
    /// 3840 px panel), or a frame of the video.
    nonisolated static func backdropNeedsFallback(_ image: UIImage?) -> Bool {
        guard let image else { return true }
        return image.size.width * image.scale < 1280 || looksLikeVideoFrame(image)
    }

    /// A background Plex cut from the video rather than an agent's artwork.
    ///
    /// Plex stores such a frame as the item's `art` on some matched titles too,
    /// at 1280x720, so neither the match nor the size gives it away (genuine
    /// TV fanart is often 1280x720 as well). What does is the video's own
    /// letterbox or pillarbox: near-black bands across the full width at top
    /// AND bottom, or the full height at left AND right. Measured on 30 server
    /// backgrounds: it flagged the 5 frames and none of the art, including 4K
    /// key art dark along its top and both sides.
    nonisolated static func looksLikeVideoFrame(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return looksLikeVideoFrame(cgImage)
    }

    nonisolated static func looksLikeVideoFrame(_ cgImage: CGImage) -> Bool {
        let width = 128, height = 72
        var luma = [UInt8](repeating: 0, count: width * height)
        let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        // Near black allows for JPEG noise in a bar; a band is two samples or
        // more (2.8% of the height, 1.6% of the width).
        let dark: UInt8 = 24
        func rowIsDark(_ y: Int) -> Bool { (0..<width).allSatisfy { luma[y * width + $0] <= dark } }
        func columnIsDark(_ x: Int) -> Bool { (0..<height).allSatisfy { luma[$0 * width + x] <= dark } }
        func run(_ count: Int, _ isDark: (Int) -> Bool) -> Int {
            var n = 0
            while n < count, isDark(n) { n += 1 }
            return n
        }
        let top = run(height) { rowIsDark($0) }
        let bottom = run(height) { rowIsDark(height - 1 - $0) }
        let left = run(width) { columnIsDark($0) }
        let right = run(width) { columnIsDark(width - 1 - $0) }
        // A video's bars are on one axis only and equal on both edges; key art
        // dark around its edges (a vignette, a black sky) is dark on both axes
        // or on one edge. A picture must remain between the bands.
        let letterboxed = top >= 2 && bottom >= 2 && abs(top - bottom) <= 1
            && left == 0 && right == 0 && top + bottom < height / 2
        let pillarboxed = left >= 2 && right >= 2 && abs(left - right) <= 1
            && top == 0 && bottom == 0 && left + right < width / 2
        return letterboxed || pillarboxed
    }
}

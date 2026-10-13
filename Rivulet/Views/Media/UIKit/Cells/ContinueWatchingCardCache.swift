// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCardCache.swift
//  Rivulet
//
//  Fetches, builds and keeps the compositor's layers and each still's analysis.
//

import UIKit
import os

nonisolated extension ContinueWatchingCardCompositor {

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    /// What to build from a source image.
    enum Layer: String {
        case card, title, titleStrong
    }

    private static func cacheKey(_ layer: Layer, _ url: URL, _ geometry: Geometry, _ scale: CGFloat) -> NSString {
        "\(layer.rawValue)#\(Int(geometry.card.width * scale))#\(url.absoluteString)" as NSString
    }

    /// An already-built layer, so a reused cell can show it with no placeholder frame.
    static func cached(_ layer: Layer, for url: URL, geometry: Geometry, scale: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(layer, url, geometry, scale))
    }

    /// The layer for a source URL: fetched and decoded by the image cache, built
    /// off the main thread, then kept by URL and pixel size.
    static func image(_ layer: Layer, for url: URL, geometry: Geometry, scale: CGFloat) async -> UIImage? {
        let key = cacheKey(layer, url, geometry, scale)
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = await ImageCacheManager.shared.image(for: url)?.cgImage else { return nil }
        let rendered = await Task.detached(priority: .userInitiated) {
            switch layer {
            case .card: render(still: source, geometry: geometry, scale: scale)
            case .title: renderTitle(logo: source, geometry: geometry, scale: scale)
            case .titleStrong: renderTitle(logo: source, geometry: geometry, scale: scale, strongShadow: true)
            }
        }.value
        guard let rendered else { return nil }
        let image = UIImage(cgImage: rendered, scale: scale, orientation: .up)
        cache.setObject(image, forKey: key, cost: rendered.bytesPerRow * rendered.height)
        return image
    }

    // MARK: - Signals

    private final class SignalsBox {
        let signals: Signals
        init(_ signals: Signals) { self.signals = signals }
    }

    private static let signalsCache = NSCache<NSString, SignalsBox>()
    private static let analysing = OSAllocatedUnfairLock(initialState: [URL: Task<Signals, Never>]())

    /// A still's analysis, run once per URL off the main thread and kept. It is
    /// in unit image coordinates, so one result serves every geometry and scale.
    static func signals(for url: URL) async -> Signals {
        let key = url.absoluteString as NSString
        if let box = signalsCache.object(forKey: key) { return box.signals }
        let task = analysing.withLock { running in
            if let task = running[url] { return task }
            let task = Task.detached(priority: .userInitiated) { () -> Signals in
                defer { analysing.withLock { $0[url] = nil } }
                // A failed fetch is not kept: the next display tries again.
                guard let source = await ImageCacheManager.shared.image(for: url)?.cgImage else { return .none }
                let signals = analyse(source)
                signalsCache.setObject(SignalsBox(signals), forKey: url.absoluteString as NSString)
                return signals
            }
            running[url] = task
            return task
        }
        return await task.value
    }
}

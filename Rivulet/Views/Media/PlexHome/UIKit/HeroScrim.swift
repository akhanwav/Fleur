// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroScrim.swift
//  Rivulet
//
//  How much extra darkening the Home hero's text stack needs over a backdrop,
//  read from a small luminance grid of the artwork.
//

import CoreGraphics

nonisolated enum HeroScrim {

    typealias Grid = ContinueWatchingCardCompositor.Grid

    /// 1 is the fixed scrim. The boost layer's opacity is `strength - 1`.
    static let maxStrength = 1.3
    /// The artwork's bright side under the text (mean luminance plus its
    /// spread) where the boost starts, and where it is full.
    static let comfortable = 0.5, glaring = 0.85

    /// The scrim strength for a text stack on `region` (unit image
    /// coordinates). No grid, or a dark or calm region, is 1.
    static func strength(under region: CGRect, luma: Grid?) -> Double {
        guard let stats = luma?.stats(in: region) else { return 1 }
        let need = (stats.mean + stats.deviation - comfortable) / (glaring - comfortable)
        return 1 + (maxStrength - 1) * min(1, max(0, need))
    }

    /// The artwork's luminance, 64 samples across. Call off the main thread.
    static func luma(_ image: CGImage) -> Grid? {
        let width = 64, height = max(1, Int((64 * CGFloat(image.height) / CGFloat(max(1, image.width))).rounded()))
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        gray.interpolationQuality = .medium
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = gray.data else { return nil }
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: gray.bytesPerRow * height)
        return Grid(columns: width, rows: height,
                    values: (0..<width * height).map { Float(bytes[($0 / width) * gray.bytesPerRow + $0 % width]) / 255 })
    }

    /// `rect`, in a view of `bounds` that shows `imageSize` aspect-filled, in
    /// unit image coordinates.
    static func unitRect(_ rect: CGRect, in bounds: CGRect, imageSize: CGSize) -> CGRect {
        let frame = ContinueWatchingCardCompositor.aspectFill(imageSize, in: bounds)
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - frame.minX) / frame.width, y: (rect.minY - frame.minY) / frame.height,
                      width: rect.width / frame.width, height: rect.height / frame.height)
    }

    // MARK: - Boost shape

    /// The boost is a radial black gradient centred on the text stack: these
    /// alphas at these fractions of its radii.
    static let boostAlphas: [CGFloat] = [1, 1, 0.5, 0]
    static let boostLocations: [CGFloat] = [0, 0.35, 0.55, 0.8]

    /// The gradient's radii for a text stack of `size`.
    static func boostRadii(for size: CGSize) -> CGSize {
        CGSize(width: size.width * 1.1, height: size.height * 1.3)
    }
}

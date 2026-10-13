// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfImageCompositor.swift
//  Rivulet
//
//  Draws Top Shelf carousel image: backdrop aspect-filled to 16:9 canvas,
//  subtle bottom gradient for caption legibility, and (optionally) a clearLogo
//  in the top band, where the backdrop leaves it the most room. Pure UIImage in/out.
//

import UIKit

nonisolated enum TopShelfImageCompositor {

    /// Bump when the drawing changes, so files composed the old way are rebuilt.
    static let version = 2

    /// A composite's file name, from what it is built from: an unchanged item keeps its file.
    static func fileName(ratingKey: String, backdropURL: String, logoURL: String) -> String {
        "\(ratingKey)-\("\(version)|\(backdropURL)|\(logoURL)".sha256Hash().prefix(16)).jpg"
    }

    /// Analyses the backdrop to place the logo, so call off the main thread.
    static func compose(
        backdrop: UIImage,
        logo: UIImage?,
        canvasSize: CGSize = CGSize(width: 1920, height: 1080)
    ) -> UIImage {
        let place = logo.map {
            placement(logoSize: $0.size, signals: backdrop.cgImage.map(Artwork.analyse) ?? .none, canvas: canvasSize)
        }
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            let canvasRect = CGRect(origin: .zero, size: canvasSize)

            // Backdrop: aspect-fill. Clip is scoped so it can't affect the
            // gradient/logo draws that follow.
            drawAspectFill(backdrop, in: canvasRect, cgContext: ctx.cgContext)

            // Subtle bottom gradient for caption legibility.
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor] as CFArray,
                locations: [0.55, 1.0]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: canvasSize.height * 0.5),
                    end: CGPoint(x: 0, y: canvasSize.height),
                    options: [])
            }

            if let logo, let place {
                // The card's strong title shadow, at this canvas's scale.
                if place.strongShadow {
                    ctx.cgContext.setShadow(offset: CGSize(width: 0, height: canvasSize.height / 270),
                                            blur: canvasSize.height / 54,
                                            color: UIColor.black.withAlphaComponent(0.6).cgColor)
                }
                logo.draw(in: place.rect)
            }
        }
    }

    /// Draws `image` into `rect`, aspect-filling (cropping to fill, no letterboxing).
    /// The clip is scoped to a saved graphics state so it can't affect later draws.
    private static func drawAspectFill(_ image: UIImage, in rect: CGRect, cgContext: CGContext) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let imageAspect = imageSize.width / imageSize.height
        let rectAspect = rect.width / rect.height

        var drawRect = rect
        if imageAspect > rectAspect {
            // Image is wider than target: scale to fill height, crop width.
            let scaledWidth = rect.height * imageAspect
            drawRect = CGRect(
                x: rect.midX - scaledWidth / 2,
                y: rect.minY,
                width: scaledWidth,
                height: rect.height)
        } else {
            // Image is taller than target: scale to fill width, crop height.
            let scaledHeight = rect.width / imageAspect
            drawRect = CGRect(
                x: rect.minX,
                y: rect.midY - scaledHeight / 2,
                width: rect.width,
                height: scaledHeight)
        }

        cgContext.saveGState()
        cgContext.clip(to: rect)
        image.draw(in: drawRect)
        cgContext.restoreGState()
    }
}

// MARK: - Placement

/// The Continue Watching card's artwork analysis and scoring.
private typealias Artwork = ContinueWatchingCardCompositor

nonisolated extension TopShelfImageCompositor {

    /// The system's own title and buttons sit on the image from here down, as a share of its height.
    static let systemOverlayTop: CGFloat = 0.55
    /// What leaving top centre costs, per candidate: the logo moves only off a clearly worse spot.
    static let moveCosts = [0, 0.25, 0.25, 0.35]

    /// Where the logo may go: top centre (the default), top left, top right, middle left.
    /// Area-budgeted to the logo's own aspect ratio, clamped to 55% canvas width /
    /// 28% canvas height, ~6% top inset, inside the title-safe side margin.
    static func logoCandidates(for logoSize: CGSize, canvas: CGSize) -> [CGRect] {
        let ratio = logoSize.height > 0 ? logoSize.width / logoSize.height : 3.0
        let targetArea = (canvas.width * 0.35) * (canvas.height * 0.14) // area budget
        var w = (targetArea * ratio).squareRoot()
        var h = (targetArea / ratio).squareRoot()
        let maxW = canvas.width * 0.55
        let maxH = canvas.height * 0.28
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        let top = canvas.height * 0.06, margin = canvas.width / 24
        return [
            CGRect(x: canvas.width / 2 - w / 2, y: top, width: w, height: h),
            CGRect(x: margin, y: top, width: w, height: h),
            CGRect(x: canvas.width - margin - w, y: top, width: w, height: h),
            CGRect(x: margin, y: canvas.height * 0.5 - h, width: w, height: h)
        ]
    }

    /// The logo's rect on the canvas for a backdrop's signals, and whether it needs the strong shadow.
    static func placement(logoSize: CGSize, signals: ContinueWatchingCardCompositor.Signals,
                          canvas: CGSize) -> (rect: CGRect, strongShadow: Bool) {
        let candidates = logoCandidates(for: logoSize, canvas: canvas)
        let choice = Artwork.choose(among: candidates, on: CGRect(origin: .zero, size: canvas),
                                    signals: signals, surcharge: moveCosts)
        return (candidates[choice.index], choice.strongShadow)
    }
}

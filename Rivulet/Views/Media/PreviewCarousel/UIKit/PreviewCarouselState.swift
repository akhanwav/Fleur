// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewCarouselState.swift
//  Rivulet
//
//  Geometry constants and lightweight types for the UIKit preview
//  carousel. The card shell follows Apple's TV app (read from its
//  binary, tvOS 26.5); see Docs/PREVIEW_CAROUSEL_REFERENCE_LAYOUT.md.
//

import UIKit

/// Constants that govern the preview carousel layout. Card shell values
/// are Apple's own; change them only against a fresh reading.
enum PreviewCarouselGeometry {
    /// Distance from the top of the screen to the top edge of each card.
    static let topInset: CGFloat = 40

    /// Card corner radius. Applied to the center slot, the side
    /// peeks, and the expanded hero (which lerps to 0 as it grows
    /// into the fullscreen detail surface).
    static let cornerRadius: CGFloat = 36

    /// Horizontal inset used to compute the centered card's frame.
    /// `centeredFrame.width = screenWidth - 2 * centeredHorizontalInset`.
    static let centeredHorizontalInset: CGFloat = 120

    /// Gap between the centered card and either side peek.
    static let sideCardGap: CGFloat = 20

    /// Share of a card's travel its artwork counter-shifts inside the window,
    /// so the art moves at about a fifth of the card's speed on screen.
    static let parallaxFactor: CGFloat = 0.8

    /// Black dim over a card, scaled by its distance from centre (0 centred,
    /// about 0.76 on a resting neighbour).
    static let neighbourDimAlpha: CGFloat = 0.8

    /// Travel (in normalized position) over which a card's chrome fades out
    /// as it pages away from centre.
    static let contentFadeDistance: CGFloat = 0.3

    /// Card position relative to the viewport centre, -1...1 (0 centred,
    /// about 0.95 on a resting neighbour). Drives parallax, dim and hairline.
    static func normalizedPosition(cardMidX: CGFloat, cardWidth: CGFloat, in bounds: CGRect) -> CGFloat {
        let reach = (bounds.width + cardWidth) / 2
        guard reach > 0 else { return 0 }
        return max(-1, min(1, (cardMidX - bounds.midX) / reach * 1.005))
    }

    /// Horizontal inset applied to the chrome content (logo / metadata
    /// / action row) inside the card: card 120 + 40 puts the metadata left
    /// edge at screen-x 160.
    static let carouselChromeInset: CGFloat = 40
    /// That edge in screen space (160): the collapsed card's content margin.
    static var collapsedChromeInset: CGFloat { centeredHorizontalInset + carouselChromeInset }
    /// Expanded-state content margin: the single app-wide content-left edge
    /// (80, Apple's). Everything in the fullscreen detail aligns here: the
    /// chrome (logo / metadata / action row), the seasons header, every
    /// below-fold row, the standalone detail page, and the info popup padding.
    /// Sourced from `MediaRowMetrics.rowLeading` so the expanded detail, the
    /// home shelves, and the hero all share ONE margin; the expand morph's pull
    /// is derived from it (ExpandedDetailContainerView.belowFoldExpandPull).
    static var expandedChromeInset: CGFloat { MediaRowMetrics.rowLeading }

    /// Vertical reserve below the chrome — sets BOTH the chrome's bottom inset
    /// (in the carousel cell) and the height of the below-fold peek region (in
    /// the detail container), so the metadata and the episode peek move
    /// together. Lowered from 220 to push the metadata block down and thin the
    /// episode peek toward the Apple TV+ layout (action row near the bottom,
    /// episodes a shallow strip beneath it).
    static let carouselChromeShelfPeek: CGFloat = 110

    /// Duration of the expand/collapse morph (ease-in-out). Card frame,
    /// chrome insets, corner radius and hairline all run on this curve.
    static let expandAnimationDuration: TimeInterval = 0.25

    /// The collapsed card is inset left/right/top and bleeds off the SCREEN
    /// BOTTOM (Apple TV+ look — the episode strip overlaps the artwork rather
    /// than sitting below it; see `Docs/atv_ref/carousel_ref.md`). Deliberately
    /// not an aspect-ratio height: the artwork is `.scaleAspectFill` inside a
    /// clipping window, so an off-16:9 card crops instead of letterboxing, and
    /// expand only has to travel left, right, and top to reach fullscreen.
    static func centeredCardSize(in bounds: CGRect) -> CGSize {
        let width = max(0, bounds.width - 2 * centeredHorizontalInset)
        let height = max(0, bounds.height - topInset)
        return CGSize(width: width, height: height)
    }

    static func centeredCardFrame(in bounds: CGRect) -> CGRect {
        let size = centeredCardSize(in: bounds)
        return CGRect(
            x: centeredHorizontalInset,
            y: topInset,
            width: size.width,
            height: size.height
        )
    }
}

/// Slot positions for the 5-slot host. Cards live at these positions
/// in screen space. Paging shifts the *content mapping* (which item
/// each card displays), not the card identities or positions.
///
/// The two `offscreen*` slots are off-screen and serve two purposes:
///   1. They give us pre-rendered cards waiting in the wings, so the
///      first frame of a paging animation already has the right
///      artwork showing instead of asynchronously loading.
///   2. They give the cards a clean target to slide into / out of
///      without ever swapping content mid-animation.
enum PreviewCarouselSlot: Int, CaseIterable {
    case offscreenLeft = -2
    case leftPeek = -1
    case center = 0
    case rightPeek = 1
    case offscreenRight = 2
}

/// Computes the carousel frame for a card at the given slot.
///
/// The three visible slots plus the two off-screen ones, one stride apart.
func previewCarouselFrame(
    slot: PreviewCarouselSlot,
    in bounds: CGRect
) -> CGRect {
    let geom = PreviewCarouselGeometry.self
    let centered = geom.centeredCardFrame(in: bounds)

    // Each step is one full card width plus the inter-card gap.
    let stride = centered.width + geom.sideCardGap
    return centered.offsetBy(dx: stride * CGFloat(slot.rawValue), dy: 0)
}

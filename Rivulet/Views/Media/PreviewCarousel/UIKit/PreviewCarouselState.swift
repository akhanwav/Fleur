// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewCarouselState.swift
//  Rivulet
//
//  Geometry constants and lightweight types for the UIKit preview
//  carousel. Mirrors the SwiftUI `PreviewOverlayHost` constants verbatim
//  (see perf-spike/DETAIL_AUDIT.md section 2.1).
//

import UIKit

/// Constants that govern the 3-slot preview carousel layout.
///
/// Numbers were copied verbatim from the SwiftUI source so the UIKit
/// host renders pixel-identical card frames during paging. Do not
/// change without re-grounding against the audit doc.
enum PreviewCarouselGeometry {
    /// Distance from the top of the screen to the top edge of each
    /// card. SwiftUI uses 52pt; matches the inset on every card slot.
    static let topInset: CGFloat = 52

    /// Card corner radius. Applied to the center slot, the side
    /// peeks, and the expanded hero (which lerps to 0 as it grows
    /// into the fullscreen detail surface).
    static let cornerRadius: CGFloat = 28

    /// Horizontal inset used to compute the centered card's frame.
    /// `centeredFrame.width = screenWidth - 2 * centeredHorizontalInset`.
    static let centeredHorizontalInset: CGFloat = 88

    /// Gap between the centered card and either side peek.
    static let sideCardGap: CGFloat = 14

    /// Multiplier applied to a side peek's inner image translation so
    /// the artwork parallaxes as the user pages.
    static let carouselParallaxFactor: CGFloat = 0.70

    /// Horizontal inset applied to the chrome content (logo / metadata
    /// / action row) inside the card. Carousel inset 40 so the metadata left
    /// edge (card 88 + 40 = screen-x 128) sits near the card edge and
    /// left-aligns with the first of the 4 centered episode thumbs. Expanded
    /// mode 140pt (refined with the expanded episode layout in Step 3).
    static let carouselChromeInset: CGFloat = 40
    /// That edge in screen space: the collapsed card's content margin.
    static var collapsedChromeInset: CGFloat { centeredHorizontalInset + carouselChromeInset }
    /// Expanded-state content margin — the single app-wide content-left edge.
    /// Everything in the fullscreen detail aligns here: the chrome (logo /
    /// metadata / action row), the seasons header, every below-fold row, the
    /// standalone detail page, and the info popup padding. Sourced from
    /// `MediaRowMetrics.rowLeading` so the expanded detail, the home shelves,
    /// and the hero all share ONE margin (40pt). Changing that one constant
    /// moves the whole app's content margin; the expand morph's pull is
    /// derived from this (see ExpandedDetailContainerView.belowFoldExpandPull),
    /// so it stays consistent automatically.
    static var expandedChromeInset: CGFloat { MediaRowMetrics.rowLeading }

    /// Vertical reserve below the chrome — sets BOTH the chrome's bottom inset
    /// (in the carousel cell) and the height of the below-fold peek region (in
    /// the detail container), so the metadata and the episode peek move
    /// together. Lowered from 220 to push the metadata block down and thin the
    /// episode peek toward the Apple TV+ layout (action row near the bottom,
    /// episodes a shallow strip beneath it).
    static let carouselChromeShelfPeek: CGFloat = 110

    /// Duration of the expand/collapse morph. Matches SwiftUI's
    /// `previewExpandAnimation = .easeInOut(duration: 0.35)`
    /// (PreviewOverlayHost.swift:17). Card frame + chrome insets +
    /// corner radius all run on this curve.
    static let expandAnimationDuration: TimeInterval = 0.35

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
/// Mirrors `PreviewOverlayHost.carouselFrame(for:)` from the SwiftUI
/// source for the three visible slots, and extends symmetrically for
/// the two off-screen slots.
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

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BackdropPlaneView.swift
//  Rivulet
//
//  VC-owned backdrop plane that sits behind the carousel's collection
//  view and is the SINGLE SOURCE OF TRUTH for all on-screen artwork.
//
//  Each visible movie gets ONE self-clipping "window" container sized to
//  that card's frame (rounded corners, clipsToBounds). Inside each
//  container sits an oversized image view, positioned so the artwork is
//  centered on the window and offset by the card's parallax. Because each
//  container clips its OWN oversized image, panels never bleed into each
//  other's windows — there is no shared mask. (A single shared layer mask
//  over stacked full-stage image views let the topmost panel's artwork
//  leak across every window; per-panel containers fix that by
//  construction.)
//
//  During expand, the centered panel's container grows from its card
//  window to fullscreen and its corner radius lerps to 0, both driven
//  by the morph controller's single animator (see CarouselMorphController).
//  The cell no longer owns any backdrop. See
//  docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md.
//

import UIKit

final class BackdropPlaneView: UIView {
    /// One self-clipping window + artwork pair per visible movie index.
    /// `container` is sized to the card window and clips; `imageView` is
    /// oversized (full stage) and lives inside the container so the window
    /// crops it. Parallax shifts the image WITHIN its container.
    private final class Panel {
        let container = UIView()
        let imageView = UIImageView()
        /// Black wash above the artwork; alpha follows the card's distance from centre.
        let dimView = UIView()
        var index: Int
        var loadToken: UInt64 = 0
        init(index: Int) {
            self.index = index
            container.clipsToBounds = true
            container.backgroundColor = .black
            container.layer.cornerCurve = .continuous
            // Round only the TOP corners. The card extends to the screen bottom
            // and reads as bleeding off-screen toward the below-fold content,
            // connecting the poster to the details (Apple TV+ look).
            container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = false
            imageView.isOpaque = true
            imageView.backgroundColor = .black
            container.addSubview(imageView)
            dimView.backgroundColor = .black
            dimView.alpha = 0
            container.addSubview(dimView)
        }
    }

    /// Active panels keyed by movie index.
    private var panels: [Int: Panel] = [:]

    /// Current corner radius for the window containers. Lerped during morph.
    private var windowCornerRadius: CGFloat = PreviewCarouselGeometry.cornerRadius

    /// Items provider injected by the VC.
    private var items: [MediaItem] = []

    /// While a morph is in flight, sync() is suppressed so the morph
    /// controller has exclusive control of the centered panel's frames.
    var isMorphing: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Apple's surround grey; shows in the top strip and the gaps between cards.
        backgroundColor = UIColor(white: 0.16, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not Storyboard-backed") }

    func configure(items: [MediaItem]) {
        self.items = items
        artworkOverrides = [:]
    }

    /// The artwork of the server copy a card's page is on, when that is
    /// another server's (Ways to Watch, On Your Servers): its own backdrop,
    /// not the main server's.
    private var artworkOverrides: [Int: MediaArtwork] = [:]

    /// Show `artwork` behind card `index` (nil: the item's own), crossfading.
    func setArtwork(_ artwork: MediaArtwork?, for index: Int) {
        guard artworkOverrides[index]?.backdrop != artwork?.backdrop else { return }
        artworkOverrides[index] = artwork
        guard let panel = panels[index] else { return }
        loadArtwork(into: panel, crossfade: true)
    }

    // MARK: - Carousel-mode sync

    /// Position one self-clipping window container per visible card, each
    /// holding an oversized image centered on the window + parallax.
    /// Called every scroll tick. Suppressed while morphing.
    func sync(to layout: PreviewCarouselLayout, offset: CGPoint) {
        guard !isMorphing else { return }
        let stage = bounds.size
        let visible = layout.visibleIndices(at: offset)

        // Recycle panels that scrolled away.
        for (idx, panel) in panels where !visible.contains(idx) {
            panel.container.removeFromSuperview()
            panels[idx] = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in visible {
            guard idx >= 0 && idx < items.count else { continue }
            let panel = panels[idx] ?? makePanel(for: idx)

            // Card window in VIEWPORT (plane) coords.
            let cardContent = layout.cardFrame(for: idx)
            let cardWindow = CGRect(
                x: cardContent.origin.x - offset.x,
                y: cardContent.origin.y - offset.y,
                width: cardContent.width,
                height: cardContent.height
            )

            // Container = the window. It clips its oversized image.
            panel.container.frame = cardWindow
            panel.container.layer.cornerRadius = windowCornerRadius
            // The dim follows horizontal position only, never the morph: a
            // morph-timed fade on the peeks is what ripped (see expandPanel).
            panel.dimView.frame = CGRect(origin: .zero, size: cardWindow.size)
            panel.dimView.alpha = PreviewCarouselGeometry.neighbourDimAlpha
                * abs(layout.normalizedPosition(for: idx))

            // Image is full-stage sized. The two axes are positioned
            // DIFFERENTLY on purpose:
            //
            //  • X = window-centered + parallax: (W-S)/2 + parallax. The
            //    parallax cancels about 80 percent of the card's travel, so
            //    the art drifts across the screen at a fifth of the card's
            //    speed and the window slides over it (Apple's formula).
            //
            //  • Y = screen-pinned: -window.origin.y, so screen-y = Wy +
            //    (-Wy) = 0. The card is inset from the top but the
            //    artwork sits at screen-y 0 (full-bleed), the window crops
            //    the top. This makes the expand morph VERTICALLY driftless:
            //    as the window grows to fullscreen the image stays at
            //    screen-y 0 the whole time.
            //
            // For the centered card (parallax 0) screen-x is also 0, so
            // expand is horizontally driftless too — both axes converge on
            // (0,0,stage), the expandPanel endpoint.
            let parallax = layout.parallaxOffset(for: idx)
            panel.imageView.frame = CGRect(
                x: (cardWindow.width - stage.width) / 2 + parallax,
                y: -cardWindow.origin.y,
                width: stage.width,
                height: stage.height
            )
        }
        CATransaction.commit()
    }

    private func makePanel(for index: Int) -> Panel {
        let panel = Panel(index: index)
        addSubview(panel.container)
        panels[index] = panel
        loadArtwork(into: panel)
        return panel
    }

    private func loadArtwork(into panel: Panel, crossfade: Bool = false) {
        guard panel.index >= 0 && panel.index < items.count else { return }
        let item = items[panel.index]
        let artwork = artworkOverrides[panel.index] ?? item.artwork
        panel.loadToken &+= 1
        let token = panel.loadToken
        guard Self.hasBackdrop(item, artwork: artwork) else {
            panel.imageView.image = nil
            return
        }
        Task { [weak panel] in
            let image = await Self.backdropImage(for: item, artwork: artwork)
            await MainActor.run {
                guard let panel, panel.loadToken == token else { return }
                guard crossfade, image != nil else { panel.imageView.image = image; return }
                UIView.transition(with: panel.imageView, duration: 0.4, options: .transitionCrossDissolve) {
                    panel.imageView.image = image
                }
            }
        }
    }

    /// Whether `backdropImage` has anything to load for `item`.
    static func hasBackdrop(_ item: MediaItem, artwork: MediaArtwork? = nil) -> Bool {
        let artwork = artwork ?? item.artwork
        return artwork.backdrop != nil || artwork.poster != nil
            || (!item.isMetadataOnly && ArtworkFallback.Query(item) != nil)
    }

    /// The one rule for a card's backdrop, used by this plane AND by the
    /// entry flight, so the two never show different art: the server's own
    /// background at full size; TMDB's when the server has none or it is far
    /// below screen size (an item no agent matched); else the poster.
    static func backdropImage(for item: MediaItem, artwork: MediaArtwork? = nil) async -> UIImage? {
        let artwork = artwork ?? item.artwork
        let fallback = item.isMetadataOnly ? nil : ArtworkFallback.Query(item)
        var image: UIImage?
        if let url = artwork.backdrop ?? (fallback == nil ? artwork.poster : nil) {
            image = await ImageCacheManager.shared.image(for: url, quality: .full)
        }
        if let fallback, (image.map { $0.size.width * $0.scale } ?? 0) < 1280,
           let tmdbURL = await ArtworkFallback.shared.backdrop(for: fallback),
           let tmdb = await ImageCacheManager.shared.image(for: tmdbURL, quality: .full) {
            image = tmdb
        }
        if image == nil, let poster = artwork.poster {
            image = await ImageCacheManager.shared.image(for: poster, quality: .full)
        }
        return image
    }

    /// The artwork already loaded for `index`, for the shelf flight's cards.
    func image(for index: Int) -> UIImage? { panels[index]?.imageView.image }

    // MARK: - Morph hooks (driven by CarouselMorphController)

    /// Current viewport frame of the panel container at `index`. Used by
    /// the morph controller as the morph's start frame.
    func panelRect(for index: Int) -> CGRect {
        return panels[index]?.container.frame ?? .zero
    }

    /// Grow the centered panel's container to `rect` (fullscreen), resize
    /// its image to fill, and hide all other panels. Called inside the
    /// morph animator's block so the frame changes tween on that curve.
    /// `isMorphing` must be true.
    func expandPanel(_ index: Int, to rect: CGRect) {
        guard let panel = panels[index] else { return }
        // Centered panel on top: as it grows to fullscreen it geometrically
        // COVERS the peeks (which stay at their carousel frames, alpha 1).
        // We deliberately do NOT alpha-fade the peeks — an alpha timeline
        // disjoint from the centered card's geometric grow/shrink caused the
        // peek "ripping" artifact during the morph. Pure geometry: cover on
        // expand, reveal on collapse.
        bringSubviewToFront(panel.container)
        panel.container.frame = rect
        panel.imageView.frame = CGRect(origin: .zero, size: rect.size)
        panel.dimView.frame = panel.imageView.frame
    }

    /// Reverse of expandPanel: shrink the centered panel's container back
    /// to its carousel window, restore its oversized centered image, and
    /// reveal the other panels. Called inside the (reversed) morph block.
    func collapsePanel(_ index: Int, to window: CGRect, parallax: CGFloat, stage: CGSize) {
        guard let panel = panels[index] else { return }
        // Keep the morphing (centered) panel on top for the whole collapse.
        // Panels are z-ordered by add order (ascending visible index), so a
        // higher-index peek sits ABOVE the centered panel. Without this, the
        // peeks (whose alpha is animated 0->1 below) fade in OVER the still-
        // large, shrinking centered card and show through its edge — the
        // "poster behind the black border" artifact. Same z-order family as
        // the original bleed bug.
        bringSubviewToFront(panel.container)
        panel.container.frame = window
        // Carousel endpoint — must match sync() exactly: X window-centered +
        // parallax (travels with the card), Y screen-pinned (-window.origin.y).
        panel.imageView.frame = CGRect(
            x: (window.width - stage.width) / 2 + parallax,
            y: -window.origin.y,
            width: stage.width,
            height: stage.height
        )
        panel.dimView.frame = CGRect(origin: .zero, size: window.size)
        // Peeks were never alpha-hidden (see expandPanel) — they sit at their
        // carousel frames and are revealed geometrically as the centered card
        // shrinks. Nothing to restore here.
    }

    /// Set the container corner radius for the panel at `index` (lerped
    /// to and from 0 by the morph controller's display-link tick). Disables CA
    /// actions so the per-frame ticks don't each spawn an implicit
    /// animation.
    func setWindowCornerRadius(_ radius: CGFloat, for index: Int) {
        windowCornerRadius = radius
        guard let panel = panels[index] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.container.layer.cornerRadius = radius
        CATransaction.commit()
    }
}

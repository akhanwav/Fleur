// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewCardView.swift
//  Rivulet
//
//  One hero card in the preview carousel. A UICollectionViewCell so
//  the collection view handles cell recycling + positioning; we
//  override `apply(_:)` to read parallax + alpha from custom layout
//  attributes computed by `PreviewCarouselLayout` based on the
//  cell's distance from the centered viewport position.
//
//  This cell is the carousel-stable host of `MediaDetailChromeView`.
//  Layout of the chrome content itself (logo / genre / description /
//  quality / action+cast row) lives in `MediaDetailChromeView` so the
//  same code drives the expanded-detail surface. The cell adds:
//   - backdrop (full-stage sized, parallaxed, clipped by the card)
//   - vignette gradients (Apple's three scrim layers)
//   - corner-clipped card window
//   - the chrome cascade (vignette + chrome alpha 0→1 on becoming current)
//
//  Chrome fade (selected center cell only), after Apple's TV app:
//   - Vignette + chrome fade in together once paging settles, 0.5s
//     ease-in-out, no delay.
//   - While paging away they fade against the card's travel
//     (`setPagingFade`), gone after 0.3 of normalized position.
//
//  Designed to keep offscreen passes near zero outside the entry
//  storm: no Material, no shadows. The vignette is three gradient-backed
//  UIViews (GradientView, layerClass = CAGradientLayer) positioned by
//  Auto Layout, so they resize with the card and ride the morph
//  animator curve automatically (no layoutSubviews frame-setting).
//

import UIKit
import os.log

private let previewCardLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCardView"
)

final class PreviewCardView: UICollectionViewCell {
    static let reuseIdentifier = "PreviewCardCell"

    // MARK: - State

    /// Current item this card is showing. `nil` means the card is idle
    /// (cleared for reuse). Setting forwards to the chrome view and
    /// kicks off the backdrop image load here.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            guard !isRefreshingWatchState else { return }
            applyItem()
        }
    }

    /// Whether this cell is the currently-focused / centered card in
    /// the carousel. Drives the chrome cascade — only the current
    /// cell shows vignette + chrome. Side peeks render bare backdrop.
    ///
    /// Use `setIsCurrent(_:animated:)` rather than assigning directly
    /// so the cascade fires with the right animation behavior.
    private(set) var isCurrent: Bool = false

    /// Monotonic load token for the backdrop image fetch. Chrome view
    /// owns its own token for logo/detail fetches.
    private var loadToken: UInt64 = 0

    /// Monotonic cascade token. Bumped on every `setIsCurrent` so any
    /// in-flight delayed UIView.animate blocks from a prior cascade
    /// no-op if the cell is paged away before they fire.
    private var cascadeToken: UInt64 = 0

    // MARK: - Subviews

    /// Vignette container: holds the three scrim layers.
    /// Alpha 0 by default; cascade fades to 1.
    private let vignetteContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    // The Apple TV app's product-page scrim: three black layers, each filling the card.
    // GRADIENT-BACKED UIVIEWS (not CAGradientLayer sublayers) so their bounds
    // animate with the morph's UIViewPropertyAnimator; unit coordinates fill
    // the view at any size, so nothing sets frames in layoutSubviews.
    private let scrimLayers: [GradientView] = [
        // Bottom band: clear over the top 64 percent.
        makeScrim(.axial, from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1),
                  alphas: [0, 0, 0.03, 0.135, 0.27, 0.405, 0.54, 0.675],
                  locations: [0, 0.64, 0.71, 0.78, 0.84, 0.91, 0.95, 1.0]),
        // Radial, clear at two thirds across the top edge, darkest lower left.
        makeScrim(.radial, from: CGPoint(x: 0.667, y: 0), to: CGPoint(x: 1.727, y: 1.884),
                  alphas: [0, 0.04, 0.15, 0.30, 0.33, 0.49, 0.67, 0.85, 1.0],
                  locations: [0, 0.19, 0.36, 0.51, 0.53, 0.65, 0.77, 0.89, 1.0]),
        // Left-to-right wash across the whole width.
        makeScrim(.axial, from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0.8),
                  alphas: [0.30, 0], locations: nil)
    ]

    private static func makeScrim(_ type: CAGradientLayerType, from start: CGPoint, to end: CGPoint,
                                  alphas: [CGFloat], locations: [NSNumber]?) -> GradientView {
        let v = GradientView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.gradientLayer.type = type
        v.gradientLayer.startPoint = start
        v.gradientLayer.endPoint = end
        v.gradientLayer.colors = alphas.map { UIColor.black.withAlphaComponent($0).cgColor }
        v.gradientLayer.locations = locations
        // Follows the card's top corners, or the scrim shows as dark squares
        // against the grey surround.
        v.layer.cornerCurve = .continuous
        v.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        v.layer.masksToBounds = true
        return v
    }

    /// Shared chrome view (logo / genre / description / quality /
    /// action+cast). Anchored bottom-leading inside the card with
    /// `heroOverlayHorizontalInset` (118pt in carousel-stable mode,
    /// 140pt in expanded mode) and 220pt up from the bottom (shelf
    /// peek reserve). Alpha 0 by default; cascade fades `chromeAlpha`
    /// to 1.
    private let chromeView: MediaDetailChromeView = {
        let v = MediaDetailChromeView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.mode = .carouselStable
        v.chromeAlpha = 0
        return v
    }()

    /// 1 pt white hairline along the top and sides, like Apple's card. On the
    /// cell, above the vignette, so the scrim and the paging fade don't dim it.
    private let hairlineView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        v.layer.cornerCurve = .continuous
        v.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        return v
    }()

    /// Leading chrome inset constraint. The host carousel VC mutates
    /// `.constant` during the expand morph to slide chrome inward
    /// (118 → 140). Same view, same constraint, same chrome subview
    /// tree throughout — true visual continuity.
    private var chromeLeadingConstraint: NSLayoutConstraint!

    /// Trailing chrome inset constraint. Mirrors leading (constants
    /// are negative). The host mutates this to keep the chrome
    /// symmetric during morph.
    private var chromeTrailingConstraint: NSLayoutConstraint!

    /// Chrome bottom inset constraint (the shelf-peek reserve). In
    /// carousel mode this is -220 (movie) or -160 (TV) from the card
    /// bottom; same value used in expanded mode (no animation).
    /// Exposed for future iter where TV shows shrink the peek.
    private var chromeBottomConstraint: NSLayoutConstraint!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCardView is not Storyboard-backed")
    }

    private func commonInit() {
        backgroundColor = .clear
        // Stable identifier for focus diagnostics / UI automation.
        accessibilityIdentifier = "carousel.card.9f27c1"
        // Transparent: the VC-owned BackdropPlaneView renders artwork
        // behind the collection view, masked to the card windows. The
        // cell holds only vignette + chrome. No corner clip here — the
        // rounded window is the plane's mask (see BackdropPlaneView).
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false

        scrimLayers.forEach(vignetteContainer.addSubview)
        contentView.addSubview(vignetteContainer)
        contentView.addSubview(chromeView)
        addSubview(hairlineView)

        chromeLeadingConstraint = chromeView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: PreviewCarouselGeometry.carouselChromeInset
        )
        chromeTrailingConstraint = chromeView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeInset
        )
        chromeBottomConstraint = chromeView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeShelfPeek
        )

        NSLayoutConstraint.activate([
            // Vignette covers the full card; gradient stops do the fade.
            vignetteContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            vignetteContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vignetteContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vignetteContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Chrome anchored bottom-leading inside the card. The host
            // animates the inset constraint constants during expand to
            // morph 118 → 140 (carousel → expanded). Same view, same
            // constraint instance — no second view tree.
            chromeLeadingConstraint,
            chromeTrailingConstraint,
            chromeBottomConstraint,

            // 1 pt taller than the card, so the bottom stroke falls off screen.
            hairlineView.topAnchor.constraint(equalTo: topAnchor),
            hairlineView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairlineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairlineView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1)
        ])
        // Every scrim layer fills the card; the stops do the shaping.
        NSLayoutConstraint.activate(scrimLayers.flatMap { [
            $0.topAnchor.constraint(equalTo: vignetteContainer.topAnchor),
            $0.leadingAnchor.constraint(equalTo: vignetteContainer.leadingAnchor),
            $0.trailingAnchor.constraint(equalTo: vignetteContainer.trailingAnchor),
            $0.bottomAnchor.constraint(equalTo: vignetteContainer.bottomAnchor)
        ] })
    }

    // MARK: - Layout

    // No layoutSubviews override needed: the vignette gradients are now
    // gradient-backed UIViews positioned by Auto Layout (constraints in
    // commonInit), so they resize with the card automatically and ride the
    // morph animator curve. The backdrop lives in the VC-owned plane.

    // MARK: - Custom layout attribute application

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        // Backdrop + parallax are owned by BackdropPlaneView now. The
        // cell only consumes frame + alpha from the layout (handled by
        // super). Nothing cell-local to update here.
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        cascadeToken &+= 1
        isCurrent = false
        contentView.alpha = 1
        hairlineView.alpha = 1
        setCornerRadius(PreviewCarouselGeometry.cornerRadius)
        vignetteContainer.alpha = 0
        chromeView.chromeAlpha = 0
        chromeView.reset()
        item = nil
    }

    // MARK: - Chrome cascade

    /// Update whether this cell is the currently-focused center card,
    /// optionally with the timed fade-in cascade.
    ///
    /// Passing `animated: true` fades vignette and chrome in over 0.5s.
    /// Passing `animated: false` snaps to the final alpha values.
    func setIsCurrent(_ current: Bool, animated: Bool) {
        guard isCurrent != current || !animated else { return }
        isCurrent = current
        cascadeToken &+= 1
        let token = cascadeToken

        // Cancel any in-flight animations by reading the current
        // presentation alpha and committing it as the model value,
        // then issuing the new animation from there.
        let currentVignetteAlpha = vignetteContainer.layer.presentation()?.opacity ?? Float(vignetteContainer.alpha)
        let currentChromeAlpha = chromeView.layer.presentation()?.opacity ?? Float(chromeView.chromeAlpha)
        vignetteContainer.layer.removeAllAnimations()
        chromeView.layer.removeAllAnimations()
        vignetteContainer.alpha = CGFloat(currentVignetteAlpha)
        chromeView.chromeAlpha = CGFloat(currentChromeAlpha)

        if !current {
            // Snap to invisible; the travel-driven fade already ran (setPagingFade).
            vignetteContainer.alpha = 0
            chromeView.chromeAlpha = 0
            return
        }

        if !animated {
            vignetteContainer.alpha = 1
            chromeView.chromeAlpha = 1
            return
        }

        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
        ) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.vignetteContainer.alpha = 1
            self.chromeView.chromeAlpha = 1
        }
    }

    /// Fade the whole card content against paging travel (1 centred, 0 gone).
    /// On `contentView` so it multiplies an in-flight fade-in instead of fighting it.
    func setPagingFade(_ alpha: CGFloat) { contentView.alpha = alpha }

    /// Hairline strength for the card's normalized position: 0.1 centred,
    /// about 0.2 on a resting neighbour.
    func setHairline(position: CGFloat) {
        hairlineView.layer.borderColor = UIColor(white: 1, alpha: 0.1 + 0.1 * abs(position)).cgColor
    }

    /// Hairline and scrim follow the window's corner radius through the morph
    /// (display-link tick).
    func setCornerRadius(_ radius: CGFloat) {
        hairlineView.layer.cornerRadius = radius
        scrimLayers.forEach { $0.layer.cornerRadius = radius }
    }

    // MARK: - Apply

    /// Hero Play → play this item (resolved to its on-deck episode for shows by
    /// the carousel VC). Set by the VC in cellForItemAt.
    var onPlay: ((MediaItem) -> Void)?
    /// Ways to Watch → play `item` (the hero item, or a show's Play target
    /// episode) from the picked file on this server. Set by the VC in cellForItemAt.
    var onPlayVersion: ((MediaItem, String) -> Void)?
    /// Info button → show the structured info popup (carries the loaded detail).
    var onShowInfo: ((MediaItemDetail) -> Void)?

    /// Repaint the hero chrome's watch-derived bits from a re-fetched copy of
    /// the same item, without rebuilding the card (issue #228). Also updates
    /// this card's own stored item so `onPlay` resumes from the new offset.
    func refreshWatchState(from refreshed: MediaItem) {
        guard let current = item, current.ref == refreshed.ref else { return }
        isRefreshingWatchState = true
        item = refreshed
        isRefreshingWatchState = false
        chromeView.refreshWatchState(from: refreshed)
    }

    /// Set while `refreshWatchState` swaps the re-fetched item in, so the
    /// `item` `didSet` skips the backdrop/chrome rebuild.
    private var isRefreshingWatchState = false

    private func applyItem() {
        loadToken &+= 1

        // Forward to chrome view — it owns logo + metadata + detail fetch.
        // Backdrop artwork is owned by BackdropPlaneView now.
        chromeView.item = item
        chromeView.onPlay = { [weak self] in
            guard let self, let item = self.chromeView.item else { return }
            self.onPlay?(item)
        }
        chromeView.onPlayVersion = { [weak self] item, sourceID in
            self?.onPlayVersion?(item, sourceID)
        }
        chromeView.onShowFullDescription = { [weak self] detail in
            self?.onShowInfo?(detail)
        }
    }

    // MARK: - Expand state

    /// Set chrome layout mode + insets for carousel vs expanded. Corner
    /// radius and backdrop are no longer the cell's concern (plane owns
    /// them). Kept minimal; the morph controller drives the animation.
    func setExpanded(_ expanded: Bool) {
        let inset = expanded
            ? PreviewCarouselGeometry.expandedChromeInset
            : PreviewCarouselGeometry.carouselChromeInset
        chromeLeadingConstraint.constant = inset
        chromeTrailingConstraint.constant = -inset
        chromeView.mode = expanded ? .expandedDetail : .carouselStable
        // The centred card's hairline fades out as it grows to fullscreen.
        hairlineView.alpha = expanded ? 0 : 1
    }

    // MARK: - Focus

    /// Focus target for the expanded action row (the Play pill). nil until the
    /// detail loads. The VC points the focus engine at this cell when expanded;
    /// the cell redirects focus into Play.
    var actionFocusEnvironment: UIView? { chromeView.playFocusable }

    /// Fade the hero metadata (chrome) as the user scrolls into the details.
    /// 1 = full hero, 0 = hidden. Restored to 1 when scroll progress returns to 0.
    func setHeroChromeAlpha(_ alpha: CGFloat) { chromeView.chromeAlpha = alpha }

    /// Make the chrome action buttons (un)focusable — disabled while the user is
    /// in the below-fold so focus can't escape up into them.
    func setChromeActionRowFocusable(_ on: Bool) { chromeView.setActionRowFocusable(on) }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let play = chromeView.playFocusable { return [play] }
        return super.preferredFocusEnvironments
    }
}

/// A UIView whose backing layer is a CAGradientLayer. Because the gradient is
/// the view's OWN layer (not a sublayer), its bounds animate as a first-class
/// UIView property — so the gradient rides a UIViewPropertyAnimator curve and
/// resizes with the view automatically, no layoutSubviews frame-setting. The
/// gradient is configured in unit coordinates (startPoint/endPoint in [0,1],
/// fractional locations), so it fills the view identically at any size.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }
}

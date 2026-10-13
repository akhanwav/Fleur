// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCell.swift
//  Rivulet
//
//  Continue Watching tile, a clone of the Apple TV app's Up Next card
//  (Docs/atv_ref/rea_findings/tv-continue-watching.md), sized by MediaRowMetrics:
//
//    one bitmap from `ContinueWatchingCardCompositor`: the 16:9 still, then
//      its mirrored, blurred continuation in the bottom 48pt
//    title logo on the edge and at the height the still's analysis picks
//      (`ContinueWatchingCardPlacement`; text fallback)
//    status row 14pt from the bottom-left (play glyph + progress + "S1, E2 · 35m")
//
//  Wrapped in `TVCardView` for native tvOS focus motion (parallax, glow).
//

import UIKit
import TVUIKit

@MainActor
final class ContinueWatchingCell: UICollectionViewCell {
    static let reuseID = "ContinueWatchingCell"

    private let card = TVCardView()
    private let artworkImageView = UIImageView()
    private let placeholderView = UIView()
    private let placeholderIcon = UIImageView()
    private let titleLogoView = ContinueWatchingTitleLogoView()
    private let infoBar = MediaProgressInfoBar()

    private var artworkLoadTask: Task<Void, Never>?
    private var currentArtworkURL: URL?

    private let cornerRadius: CGFloat = 24

    fileprivate static let geometry = ContinueWatchingCardCompositor.Geometry(
        cardWidth: MediaRowMetrics.continueWatching.art.width)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // TVCardView provides Apple's tvOS focus motion (parallax + glow).
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = CGSize(width: MediaRowMetrics.cwWidth, height: MediaRowMetrics.cwHeight)
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: MediaRowMetrics.cwWidth),
            card.heightAnchor.constraint(equalToConstant: MediaRowMetrics.cwHeight)
        ])

        // No resting drop shadow (ATV+ reference: cards float clean over the
        // page background; see Docs/atv_ref/below_home_hero_ref.md).

        // Placeholder underlay, visible until the artwork resolves.
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.backgroundColor = UIColor(white: 1, alpha: 0.1)
        card.contentView.addSubview(placeholderView)

        // SwiftUI failure branch: dark gradient + film/play.rectangle icon.
        // We reuse the placeholder view for both empty and failure states;
        // the icon is hidden by default and shown only when the load fails.
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholderIcon.isHidden = true
        placeholderView.addSubview(placeholderIcon)

        // Artwork: the compositor's bitmap, already the card's size.
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        card.contentView.addSubview(artworkImageView)

        // Title logo (Plex clearLogo, falling back to the title).
        titleLogoView.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(titleLogoView)

        // Bottom info bar.
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(infoBar)

        let pad = ContinueWatchingCardCompositor.padding
        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 32),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 32),

            artworkImageView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            artworkImageView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),


            titleLogoView.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            titleLogoView.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            titleLogoView.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            titleLogoView.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),

            // Apple's status row: 14pt from the card's edges.
            infoBar.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: pad).withPriority(999),
            infoBar.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -pad).withPriority(999),
            infoBar.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -pad)
        ])
    }

    /// The status row's glyph, label and bar fill follow focus, on the focus clock.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations({ self.infoBar.setFocused(nowFocused) }, completion: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.contentView.layer.cornerRadius = cornerRadius
        card.contentView.layer.cornerCurve = .continuous
        card.contentView.clipsToBounds = true
        // The rim Apple's floating view draws at rest (its highlightStyle is private).
        card.contentView.layer.borderWidth = 1
        card.contentView.layer.borderColor = UIColor(white: 1, alpha: 0.05).cgColor
        CATransaction.commit()
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        // Title-logo view fetches the clearLogo asynchronously (with a
        // text fallback if there is none).
        let url = artworkURL(for: item)
        titleLogoView.configure(item: item, artworkURL: url)

        // Info bar: play icon + (optional) progress capsule + info text.
        infoBar.configure(item: item)

        loadArtwork(from: url, failureIcon: failurePlaceholderImage(for: item))
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        // Episodes/shows: prefer the grandparent (show) logo; fall back to
        // the item's own logo. The URL is already resolved — no async fetch.
        let logoURL = item.grandparentArtwork?.logo ?? item.artwork.logo
        // Backdrop > thumbnail in landscape orientation.
        let url = item.grandparentArtwork?.backdrop
            ?? item.artwork.backdrop
            ?? item.artwork.thumbnail
        titleLogoView.configure(logoURL: logoURL, fallbackTitle: item.title, artworkURL: url)

        infoBar.configure(item: item)

        loadArtwork(from: url, failureKind: item.kind)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentArtworkURL = nil
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true
        titleLogoView.prepareForReuse()
        infoBar.reset()
    }

    // MARK: - Artwork

    /// MediaItem path: resolves failure icon via MediaKind then delegates.
    private func loadArtwork(from url: URL?, failureKind: MediaKind) {
        loadArtwork(from: url, failureIcon: failurePlaceholderImage(for: failureKind))
    }

    private func loadArtwork(from url: URL?, failureIcon: UIImage?) {
        artworkLoadTask?.cancel()
        guard let url else {
            artworkImageView.image = nil
            currentArtworkURL = nil
            placeholderView.isHidden = false
            placeholderIcon.image = failureIcon
            placeholderIcon.isHidden = false
            return
        }
        if currentArtworkURL == url, artworkImageView.image != nil {
            placeholderView.isHidden = true
            return
        }
        currentArtworkURL = url
        let geometry = Self.geometry, scale = traitCollection.displayScale
        if let built = ContinueWatchingCardCompositor.cached(.card, for: url, geometry: geometry, scale: scale) {
            artworkImageView.image = built
            placeholderView.isHidden = true
            return
        }
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true  // hidden during loading
        let key = url.absoluteString as AnyHashable
        artworkLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ContinueWatchingCardCompositor.image(.card, for: url, geometry: geometry, scale: scale)
            }
            await MainActor.run {
                guard let self, self.currentArtworkURL == url else { return }
                if let image {
                    self.artworkImageView.image = image
                    self.placeholderView.isHidden = true
                } else {
                    self.placeholderIcon.image = failureIcon
                    self.placeholderIcon.isHidden = false
                }
            }
        }
    }

    private func artworkURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // SwiftUI: episodes prefer grandparentArt; otherwise art > thumb.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentArt ?? item.art ?? item.thumb
        } else {
            path = item.art ?? item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    /// PlexMetadata failure icon: "film" for movies, "play.rectangle" otherwise.
    private func failurePlaceholderImage(for item: PlexMetadata) -> UIImage? {
        let name = item.type == "movie" ? "film" : "play.rectangle"
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    /// MediaItem failure icon — maps MediaKind to a system image name.
    private func failurePlaceholderImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:   name = "film"
        case .show:    name = "tv"
        case .season:  name = "number.square"
        case .episode: name = "play.rectangle"
        case .person:  name = "person"
        default:       name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }
}

// MARK: - Title Logo (Plex clearLogo fetch)

/// The item's clearLogo (the show's, for episodes) in the slot the still's
/// analysis picks: either edge, any height. Falls back to the title as text.
/// Nothing shows until the slot is known, so the title never moves.
@MainActor
private final class ContinueWatchingTitleLogoView: UIView {
    private typealias Compositor = ContinueWatchingCardCompositor

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private var imageTop: NSLayoutConstraint!
    private var labelCenterY: NSLayoutConstraint!

    private var fetchTask: Task<Void, Never>?
    private var currentItemKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Fallback title: 30pt bold, white, soft drop shadow.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.shadowOffset = CGSize(width: 0, height: 2)
        titleLabel.alpha = 0
        addSubview(titleLabel)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.alpha = 0
        addSubview(imageView)

        // The compositor's title bitmap: the title box plus room for its shadow.
        let geometry = ContinueWatchingCell.geometry
        let box = geometry.titleBox.insetBy(dx: -Compositor.titleShadowPad, dy: -Compositor.titleShadowPad)
        imageTop = imageView.topAnchor.constraint(equalTo: topAnchor, constant: box.minY)
        labelCenterY = titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: geometry.titleBox.midY)
        NSLayoutConstraint.activate([
            // 999s: tolerate TVCardView's transient zero-width layout pass.
            // Left and right, not leading and trailing: the slot is scored on the artwork's pixels.
            titleLabel.leftAnchor.constraint(equalTo: leftAnchor, constant: geometry.titleBox.minX),
            labelCenterY,
            titleLabel.rightAnchor.constraint(equalTo: rightAnchor, constant: -geometry.titleBox.minX).withPriority(999),

            imageView.leftAnchor.constraint(equalTo: leftAnchor, constant: box.minX),
            imageTop,
            imageView.widthAnchor.constraint(equalToConstant: box.width).withPriority(999),
            imageView.heightAnchor.constraint(equalToConstant: box.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: PlexMetadata, artworkURL: URL?) {
        configure(key: "\(item.ratingKey ?? "")|\(artworkURL?.absoluteString ?? "")",
                  title: displayTitle(for: item), artworkURL: artworkURL) {
            await Self.resolveLogoURL(for: item)
        }
    }

    /// MediaItem path. The logo URL is already resolved.
    func configure(logoURL: URL?, fallbackTitle: String, artworkURL: URL?) {
        configure(key: "\(logoURL?.absoluteString ?? fallbackTitle)|\(artworkURL?.absoluteString ?? "")",
                  title: fallbackTitle, artworkURL: artworkURL) { logoURL }
    }

    /// Loads the logo and the still's analysis side by side, then shows the
    /// logo (or the title) once, in the slot they pick.
    private func configure(key: String, title: String, artworkURL: URL?, logoURL: @escaping () async -> URL?) {
        titleLabel.text = title
        // Same item: shown already, or on its way.
        guard key != currentItemKey else { return }
        fetchTask?.cancel()
        imageView.image = nil
        imageView.alpha = 0
        titleLabel.alpha = 0
        currentItemKey = key

        let geometry = ContinueWatchingCell.geometry, scale = traitCollection.displayScale
        let textSize = titleLabel.intrinsicContentSize
        fetchTask = Task { [weak self] in
            async let analysed = Self.signals(for: artworkURL)
            var logo: (url: URL, size: CGSize)?
            if let url = await logoURL(), let size = await ImageCacheManager.shared.image(for: url)?.size {
                logo = (url, size)
            }
            let placement = Compositor.placement(signals: await analysed, logoSize: logo?.size,
                                                 textSize: textSize, geometry: geometry)
            var image: UIImage?
            if let logo {
                image = await Compositor.image(placement.strongShadow ? .titleStrong : .title, for: logo.url,
                                               geometry: geometry, scale: scale)
            }
            guard !Task.isCancelled, let self, self.currentItemKey == key else { return }
            self.show(image, logoSize: logo?.size, placement: placement)
        }
    }

    private static func signals(for artworkURL: URL?) async -> Compositor.Signals {
        guard let artworkURL else { return .none }
        return await Compositor.signals(for: artworkURL)
    }

    func prepareForReuse() {
        fetchTask?.cancel()
        fetchTask = nil
        currentItemKey = nil
        imageView.image = nil
        imageView.alpha = 0
        titleLabel.alpha = 0
        titleLabel.text = nil
    }

    private func displayTitle(for item: PlexMetadata) -> String {
        if item.type == "episode" {
            return item.grandparentTitle ?? item.title ?? "Unknown"
        }
        return item.title ?? "Unknown"
    }

    /// Both configure paths end here: move to the slot, then fade in.
    private func show(_ image: UIImage?, logoSize: CGSize?, placement: Compositor.Placement) {
        let geometry = ContinueWatchingCell.geometry
        let box = geometry.titleBox.offsetBy(dx: 0, dy: placement.offset)
        imageTop.constant = box.minY - Compositor.titleShadowPad
        labelCenterY.constant = box.midY
        titleLabel.textAlignment = placement.side == .leading ? .left : .right
        titleLabel.shadowColor = UIColor.black.withAlphaComponent(placement.strongShadow ? 0.8 : 0.5)
        imageView.image = image
        // The bitmap holds the logo on the box's leading edge: carry it to its
        // slot, so a smaller or trailing logo keeps the edge it sits on.
        let resting = geometry.titleFootprint(logoSize: logoSize)
        let slot = geometry.titleRect(resting, side: placement.side, scale: placement.scale)
        imageView.transform = CGAffineTransform(
            translationX: slot.midX - box.midX - (resting.midX - box.midX) * placement.scale, y: 0)
            .scaledBy(x: placement.scale, y: placement.scale)
        layoutIfNeeded()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
            (image == nil ? self.titleLabel : self.imageView).alpha = 1
        }
    }

    /// Resolve the clearLogo URL — for episodes/shows, fetch the
    /// grandparent metadata (hub items don't carry the Image array).
    /// Caches the full-metadata response via PlexDataStore for reuse.
    private static func resolveLogoURL(for item: PlexMetadata) async -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            return nil
        }
        // The hub item already carries grandparentRatingKey, so resolve the
        // source key directly (one metadata fetch) via the shared resolver.
        guard let ratingKey = TopShelfLogoResolver.sourceRatingKey(for: item) else { return nil }

        // Plain metadata, not `getFullMetadata`: the only field read below is
        // `clearLogoPath`, and the seven include params buy nothing here while
        // costing 28% more bytes and twice the latency. This runs once per
        // visible cell, so it is the app's one per-item metadata fan-out and
        // showed up in Sentry as an N+1 (RIVULET-V).
        let sourceMetadata: PlexMetadata
        if let cached = PlexDataStore.shared.getCachedLogoMetadata(for: ratingKey) {
            sourceMetadata = cached
        } else {
            do {
                let fetched = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                PlexDataStore.shared.cacheLogoMetadata(fetched, for: ratingKey)
                sourceMetadata = fetched
            } catch {
                return nil
            }
        }

        let urlString = TopShelfLogoResolver.logoURLString(from: sourceMetadata, serverURL: serverURL, token: token)
        return urlString.isEmpty ? nil : URL(string: urlString)
    }
}

// Info bar moved to `Rivulet/Views/Media/UIKit/Cells/MediaProgressInfoBar.swift`
// for reuse by PosterCell (in-progress items in Recently Added /
// Personalized Recommendations rows render the same composition).

extension ContinueWatchingCell: PreviewSourceTile {
    var previewArtworkView: UIView { card.contentView }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { artworkImageView.image != nil }
}

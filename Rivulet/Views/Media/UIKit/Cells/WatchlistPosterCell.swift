// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchlistPosterCell.swift
//  Rivulet
//
//  Poster tile for the Watchlist hub row on the UIKit home. Mirrors
//  SwiftUI `WatchlistTile` (`WatchlistHubRow.swift:237-290`):
//   - poster image surface, 20pt rounded-rect mask, .continuous corner curve
//   - no resting drop shadow (ATV+ ref: cards float clean over the background)
//   - `.hoverEffect(.highlight)` approximated via `TVPosterView` focus motion
//   - placeholder when no posterURL: dark gradient + film/tv SF symbol
//     (32pt light, white-0.3)
//
//  TVPosterView's own caption (`title` / `subtitle`) is intentionally nil —
//  see comment in `PosterCell.swift` for the rationale (TVPosterView reserves
//  bottom caption space that crops 2:3 posters). A tile that needs a caption
//  (the person page's filmography: title, year, character) gets labels of
//  this cell's own below the lockup frame, `configure(item:badge:caption:)`.
//

import UIKit
import TVUIKit

@MainActor
final class WatchlistPosterCell: UICollectionViewCell {
    static let reuseID = "WatchlistPosterCell"

    private let posterView = TVPosterView()
    /// Overlay clipped to the same rounded rect — shows the placeholder
    /// gradient + icon when there is no poster URL or the load fails.
    private let placeholderView = UIView()
    private let placeholderGradient = CAGradientLayer()
    private let placeholderIcon = UIImageView()
    /// The badge `configure(item:badge:caption:)` may set, top-leading, in
    /// `PosterCell`'s server-name style. Watchlist entries carry none: which
    /// servers hold a title is Ways to Watch's to say.
    private let ownedBadge = SourceBadgeView(style: .onArtwork)

    /// Lines under the poster for `configure(item:badge:caption:)`.
    struct Caption {
        let title: String
        let detail: String?
        /// Up to two lines, then "…".
        let credit: String?
    }
    private static let captionTitleFont = UIFont.systemFont(ofSize: 23, weight: .semibold)
    private static let captionFont = UIFont.systemFont(ofSize: 19, weight: .medium)
    private static let captionTopGap: CGFloat = 10
    /// The caption block's height below the lockup frame (title, detail and
    /// two credit lines); add it to the cell's height to show one.
    static let captionHeight: CGFloat = captionTopGap + ceil(captionTitleFont.lineHeight)
        + 2 + ceil(captionFont.lineHeight) + 2 + ceil(captionFont.lineHeight * 2)

    private let captionStack = UIStackView()
    private let captionTitle = UILabel()
    private let captionDetail = UILabel()
    private let captionCredit = UILabel()

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?
    /// True once real artwork is showing; `posterView.image` is never nil.
    private var hasArtwork = false

    private let cornerRadius: CGFloat = 20
    private let posterWidth: CGFloat = MediaRowMetrics.posterWidth
    private let posterHeight: CGFloat = MediaRowMetrics.posterHeight

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // No resting drop shadow (ATV+ reference: cards float clean over the
        // page background; see Docs/atv_ref/below_home_hero_ref.md).

        posterView.translatesAutoresizingMaskIntoConstraints = false
        posterView.image = PosterCell.blankArtwork
        contentView.addSubview(posterView)

        // Placeholder underlay (dark gradient + centred SF symbol). Visible
        // when posterURL is nil or the load fails. Sits behind the poster
        // image so the image hides it once loaded.
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.clipsToBounds = true
        placeholderView.layer.cornerRadius = cornerRadius
        placeholderView.layer.cornerCurve = .continuous
        placeholderGradient.colors = [
            UIColor(white: 0.18, alpha: 1.0).cgColor,
            UIColor(white: 0.12, alpha: 1.0).cgColor
        ]
        placeholderGradient.startPoint = CGPoint(x: 0.5, y: 0)
        placeholderGradient.endPoint = CGPoint(x: 0.5, y: 1)
        placeholderView.layer.addSublayer(placeholderGradient)

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholderView.addSubview(placeholderIcon)

        // Insert placeholder below the poster view so the image covers it.
        contentView.insertSubview(placeholderView, belowSubview: posterView)

        ownedBadge.translatesAutoresizingMaskIntoConstraints = false
        posterView.imageView.addSubview(ownedBadge)

        captionTitle.font = Self.captionTitleFont
        captionTitle.textColor = .white
        captionDetail.font = Self.captionFont
        captionDetail.textColor = UIColor.white.withAlphaComponent(0.6)
        captionCredit.font = Self.captionFont
        captionCredit.textColor = UIColor.white.withAlphaComponent(0.6)
        captionCredit.numberOfLines = 2
        captionCredit.lineBreakMode = .byTruncatingTail
        captionStack.axis = .vertical
        captionStack.spacing = 2
        captionStack.alignment = .fill
        captionStack.isHidden = true
        captionStack.translatesAutoresizingMaskIntoConstraints = false
        [captionTitle, captionDetail, captionCredit].forEach(captionStack.addArrangedSubview)
        contentView.addSubview(captionStack)
        // Under the frame, not the resting artwork: a focused poster grows
        // to fill the frame, and the caption stays clear of it.
        let artInset = (posterWidth - MediaRowMetrics.poster.art.width) / 2

        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: posterWidth),
            posterView.heightAnchor.constraint(equalToConstant: posterHeight),

            placeholderView.topAnchor.constraint(equalTo: posterView.imageView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: posterView.imageView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: posterView.imageView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: posterView.imageView.trailingAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 32),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 32),

            ownedBadge.topAnchor.constraint(equalTo: posterView.imageView.topAnchor, constant: 10),
            ownedBadge.leadingAnchor.constraint(equalTo: posterView.imageView.leadingAnchor, constant: 10),

            captionStack.topAnchor.constraint(equalTo: posterView.bottomAnchor, constant: Self.captionTopGap),
            captionStack.leadingAnchor.constraint(equalTo: posterView.leadingAnchor, constant: artInset),
            captionStack.trailingAnchor.constraint(equalTo: posterView.trailingAnchor, constant: -artInset),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the gradient sized to the placeholder bounds (no implicit
        // animation so it doesn't interpolate the frame on every layout
        // pass when the cell is recycled).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderGradient.frame = placeholderView.bounds
        CATransaction.commit()
    }

    func configure(item: PlexWatchlistItem) {
        // Pick the SF Symbol that matches the watchlist type — `film` for
        // movies, `tv` for shows. Mirrors SwiftUI `WatchlistTile.placeholder`.
        let iconName = item.type == .movie ? "film" : "tv"
        let icon = UIImage(systemName: iconName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
        loadImage(from: item.posterURL, failureIcon: icon)
        ownedBadge.text = nil
        showTitleCaption(item.title, year: item.year)
    }

    /// Title and year only (the Watchlist), when the setting is on. The
    /// filmography's three-line caption is `configure(item:badge:caption:)`.
    private func showTitleCaption(_ title: String, year: Int?) {
        guard MediaRowMetrics.showsPosterTitles else { captionStack.isHidden = true; return }
        captionTitle.text = title
        captionDetail.text = year.map(String.init) ?? " "
        captionDetail.isHidden = false
        captionCredit.isHidden = true
        captionStack.isHidden = false
    }

    /// MediaItem path. Artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        loadImage(from: item.artwork.poster, failureIcon: failureIconImage(for: item.kind))
        showTitleCaption(item.title, year: item.year)
    }

    /// MediaItem with a badge (e.g. "On Server") and the caption lines below.
    func configure(item: MediaItem, badge: String?, caption: Caption) {
        configure(item: item)
        ownedBadge.text = badge
        captionTitle.text = caption.title
        captionDetail.text = caption.detail
        captionDetail.isHidden = caption.detail == nil
        captionCredit.text = caption.credit
        captionCredit.isHidden = caption.credit == nil
        captionStack.isHidden = false
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        FocusRim.remove(in: posterView, focused: nowFocused, coordinator: coordinator)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        clearArtwork()
        placeholderView.isHidden = false
        placeholderIcon.image = nil
        ownedBadge.text = nil
        captionStack.isHidden = true
    }

    private func loadImage(from url: URL?, failureIcon: UIImage?) {
        imageLoadTask?.cancel()
        // Update the placeholder icon regardless of whether we have a URL.
        placeholderIcon.image = failureIcon
        guard let url else {
            clearArtwork()
            currentURL = nil
            // No URL: show placeholder (no fade-out animation needed).
            placeholderView.isHidden = false
            return
        }
        if currentURL == url, hasArtwork {
            placeholderView.isHidden = true
            return
        }
        currentURL = url
        // Memory hit paints in this pass, so a tile realized for the carousel
        // exit has artwork to fly to.
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            posterView.image = cached
            hasArtwork = true
            placeholderView.isHidden = true
            return
        }
        placeholderView.isHidden = false  // visible while loading
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                if let image {
                    self.posterView.image = image
                    self.hasArtwork = true
                    self.placeholderView.isHidden = true
                } else {
                    // Load failed: keep placeholder visible.
                    self.placeholderView.isHidden = false
                }
            }
        }
    }

    private func clearArtwork() {
        posterView.image = PosterCell.blankArtwork
        hasArtwork = false
    }

    /// MediaItem failure icon -- maps MediaKind to a system image name.
    private func failureIconImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:      name = "film"
        case .show:       name = "tv"
        case .season:     name = "number.square"
        case .episode:    name = "play.rectangle"
        case .person:     name = "person"
        default:          name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }
}

extension WatchlistPosterCell: PreviewSourceTile {
    var previewArtworkView: UIView { posterView.imageView }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { hasArtwork }
}

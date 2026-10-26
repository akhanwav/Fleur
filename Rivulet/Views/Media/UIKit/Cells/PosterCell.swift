// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PosterCell.swift
//  Rivulet
//
//  Poster-style hub cell (Recently Added rows, Personalized Recommendations).
//  Wraps `TVPosterView` for native tvOS focus motion (parallax, scale, glow).
//
//  Caption (`title` / `subtitle`) is intentionally nil. When set,
//  `TVPosterView` reserves bottom space for the on-focus caption block
//  even while the caption is hidden, which compresses the image area and
//  visibly crops the bottom of 2:3 Plex posters. SwiftUI MediaPosterCard
//  doesn't render a caption either; the title surfaces in the preview
//  overlay / detail view instead.
//
//  Overlay subviews (unwatched-count badge, server badge, failure icon)
//  live in a sibling `overlayContainer` view that:
//    * matches the poster's image surface
//    * applies its own 20pt corner mask so the watched corner-tag clips
//      to the same rounded edge as the poster image
//    * tracks the cell's focus state and applies the same scale
//      transform `TVPosterView` uses for the image (so overlays grow
//      with the poster instead of staying static during focus zoom)
//
//  Earlier attempts to host overlays inside `posterView.contentView` or
//  `posterView.imageView` either produced invisible badges (Apple's
//  internal layout doesn't render subviews on the imageView) or didn't
//  inherit clipping correctly. The sibling-with-matching-transform
//  approach is reliable on both counts.
//
//  No watch-progress bar and no watched glyph on a poster: progress shows
//  on the title's detail page (and on Continue Watching's own cards). A
//  show with unwatched episodes keeps its count pill.
//

import UIKit
import TVUIKit

@MainActor
final class PosterCell: UICollectionViewCell {
    static let reuseID = "PosterCell"

    private let posterView = TVPosterView()

    /// Sibling of `posterView` that hosts overlays. Has its own rounded
    /// mask so the corner-tag clips to the same shape as the poster; its
    /// transform is kept in sync with the posterView's focus zoom in
    /// `didUpdateFocus`.
    private let overlayContainer = UIView()

    private let watchedBadge = PosterWatchedBadge()
    private let sourceBadge = SourceBadgeView(style: .onArtwork)
    /// Search only: the result's quality and server, bottom-leading.
    private let versionTags = VersionTagsView()
    /// Title and year under the frame (see `PosterCaptionView`).
    private let caption = PosterCaptionView()
    private let failureIcon = UIImageView()

    /// Glass card shown in place of the bare `TVPosterView` gray while the
    /// artwork loads (and on a genuine load failure, with the faint type icon
    /// on top). Plain view, not a blur — a UIVisualEffectView per cell is a
    /// measured perf cost.
    private let placeholderPanel = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    /// Delays the spinner so a fast cache hit doesn't flash it on scroll.
    private var spinnerDelayTask: Task<Void, Never>?

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?
    /// True once real artwork is showing. `posterView.image` is never nil
    /// (see `blankArtwork`), so it cannot answer this.
    private var hasArtwork = false

    /// Stand-in for missing artwork. TVPosterView drops its focus-growth
    /// inset with a nil image, which made a loading tile larger than a loaded one.
    static let blankArtwork = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// The system image corner on tvOS 26.
    private let cornerRadius: CGFloat = 20
    private let posterWidth: CGFloat = MediaRowMetrics.posterWidth
    private let posterHeight: CGFloat = MediaRowMetrics.posterHeight

    /// Swappable so music tiles render the 1:1 square lockup instead of the
    /// 2:3 poster one. Set per item in `configure(...)`.
    private var posterWidthConstraint: NSLayoutConstraint!
    private var posterHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // Stable identifier for focus diagnostics / UI automation.
        accessibilityIdentifier = "hub.poster.cell.9f27c1"

        // No resting drop shadow: the ATV+ reference (Docs/atv_ref/
        // below_home_hero_ref.md) floats cards directly over the page
        // background — focus chrome is image-bound, no dark halo.

        posterView.translatesAutoresizingMaskIntoConstraints = false
        posterView.image = Self.blankArtwork
        contentView.addSubview(posterView)

        // Overlay container clipped to the same rounded rect as the poster.
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isUserInteractionEnabled = false
        overlayContainer.clipsToBounds = true
        overlayContainer.layer.cornerRadius = cornerRadius
        overlayContainer.layer.cornerCurve = .continuous
        contentView.addSubview(overlayContainer)

        // Glass placeholder (backmost): covers TVPosterView's bare gray while
        // the artwork loads, and hosts the failure icon on a genuine miss. A
        // neutral dark fill (slightly above the page background) + a hairline
        // edge reads as a calm card, not Apple's lighter empty-poster gray.
        placeholderPanel.translatesAutoresizingMaskIntoConstraints = false
        placeholderPanel.isUserInteractionEnabled = false
        placeholderPanel.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        placeholderPanel.layer.cornerRadius = cornerRadius
        placeholderPanel.layer.cornerCurve = .continuous
        placeholderPanel.layer.borderWidth = 1
        placeholderPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        placeholderPanel.isHidden = true
        overlayContainer.addSubview(placeholderPanel)

        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.color = UIColor.white.withAlphaComponent(0.7)
        loadingSpinner.hidesWhenStopped = true
        overlayContainer.addSubview(loadingSpinner)

        // Watched badge: top-trailing, 10pt inset (mirrors SwiftUI `.padding(10)`).
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        watchedBadge.isHidden = true
        overlayContainer.addSubview(watchedBadge)

        // Server badge: top-leading, 10pt inset. Set by the caller after configure.
        sourceBadge.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.addSubview(sourceBadge)

        versionTags.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.addSubview(versionTags)

        // Failure icon: centred. Hidden by default; visible only when the
        // image load fails or the source URL is missing.
        failureIcon.translatesAutoresizingMaskIntoConstraints = false
        failureIcon.contentMode = .scaleAspectFit
        failureIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        failureIcon.isHidden = true
        overlayContainer.addSubview(failureIcon)

        contentView.addSubview(caption)
        caption.pin(below: posterView, artInset: (posterWidth - MediaRowMetrics.poster.art.width) / 2)
        caption.isHidden = true

        posterWidthConstraint = posterView.widthAnchor.constraint(equalToConstant: posterWidth)
        posterHeightConstraint = posterView.heightAnchor.constraint(equalToConstant: posterHeight)
        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterWidthConstraint,
            posterHeightConstraint,

            // Pin to TVPosterView's IMAGE surface, not its outer frame: the
            // frame reserves room for focus growth, so the resting picture is
            // smaller and an overlay on the outer frame hangs off it.
            overlayContainer.topAnchor.constraint(equalTo: posterView.imageView.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: posterView.imageView.bottomAnchor),
            overlayContainer.leadingAnchor.constraint(equalTo: posterView.imageView.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: posterView.imageView.trailingAnchor),

            watchedBadge.topAnchor.constraint(equalTo: overlayContainer.topAnchor, constant: 10),
            watchedBadge.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -10),
            sourceBadge.topAnchor.constraint(equalTo: overlayContainer.topAnchor, constant: 10),
            sourceBadge.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 10),
            versionTags.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor, constant: -10),
            versionTags.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 10),
            versionTags.trailingAnchor.constraint(lessThanOrEqualTo: overlayContainer.trailingAnchor, constant: -10),

            failureIcon.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            failureIcon.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
            failureIcon.widthAnchor.constraint(equalToConstant: 32),
            failureIcon.heightAnchor.constraint(equalToConstant: 32),

            // Glass placeholder fills the image surface; spinner centered on it.
            placeholderPanel.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
            placeholderPanel.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            placeholderPanel.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            placeholderPanel.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
        ])
    }

    // MARK: - Focus zoom sync

    /// The focused image grows by `focusGrowth` on its longer side, and that
    /// growth doesn't reach our sibling `overlayContainer`, so mirror it here.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        FocusRim.remove(in: posterView, focused: nowFocused, coordinator: coordinator)
        versionTags.setFocused(nowFocused)
        watchedBadge.setFocused(nowFocused)
        let artSize = posterView.imageView.bounds.size
        let longSide = max(artSize.width, artSize.height)
        let scale = longSide > 0 ? 1 + MediaRowMetrics.focusGrowth / longSide : 1.1
        coordinator.addCoordinatedAnimations({
            self.overlayContainer.transform = nowFocused
                ? CGAffineTransform(scaleX: scale, y: scale)
                : .identity
        }, completion: { [weak self] in
            guard let self, !nowFocused else { return }
            // TVPosterView owns its focus scale and shrinks via its own
            // coordinated unfocus animation — which sometimes does NOT reset
            // (the poster stays enlarged with the engine reporting it
            // unfocused, so no further event will fix it). Once the focus
            // animation settles, enforce the unfocused end state ourselves.
            self.resetStaleFocusAppearance()
        })
    }

    /// Force-clear a stale focused appearance. TVPosterView owns its focus
    /// scale and the remote-tilt motion effects; both are torn down by its own
    /// coordinated unfocus animation, which sometimes never runs (e.g. focus
    /// left the whole collection into a presented carousel) — the poster
    /// strands enlarged AND keeps parallax-wiggling with the remote while the
    /// engine reports it unfocused, so no further event will fix it. Clear any
    /// leftover scale transform and strip motion effects from the poster's
    /// view tree directly. No-ops if the cell is (or became) focused — the
    /// unfocus-completion trigger can land after focus has already returned to
    /// this cell, and must not wipe a live focused appearance.
    func resetStaleFocusAppearance() {
        guard !isFocused else { return }
        func clear(_ v: UIView) {
            if !v.transform.isIdentity { v.transform = .identity }
            if !CATransform3DIsIdentity(v.layer.transform) { v.layer.transform = CATransform3DIdentity }
            v.motionEffects.forEach { v.removeMotionEffect($0) }
            v.subviews.forEach(clear)
        }
        clear(posterView)
        overlayContainer.transform = .identity
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        sourceBadge.text = nil
        versionTags.clear()
        setSquare(["artist", "album", "track"].contains(item.type ?? ""))
        setFallbackQuery(ArtworkFallback.Query(item))
        let isAudio = ["artist", "album", "track"].contains(item.type ?? "")
        caption.configure(title: isAudio ? nil : (item.type == "episode" ? item.grandparentTitle ?? item.title : item.title),
                          year: item.type == "episode" ? nil : item.year)
        let url = posterURL(for: item)
        loadImage(from: url, item: item)
        configureWatchedBadge(item: item)
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        sourceBadge.text = nil
        versionTags.clear()
        cancelSeasonCount()
        setSquare(item.isMusic == true)
        setFallbackQuery(item.isMusic == true ? nil : ArtworkFallback.Query(item))
        caption.configure(title: item.isMusic == true ? nil : (item.kind == .episode ? item.seriesTitle ?? item.title : item.title),
                          year: item.kind == .episode ? nil : item.year)
        // Episodes prefer the grandparent (show) poster so hub rows render
        // show art instead of letterboxed episode stills, matching the Plex path.
        let url = item.grandparentArtwork?.poster ?? item.artwork.poster
        loadImage(from: url, failureKind: item.kind)
        configureWatchedBadge(item: item)
    }

    /// Names the item's server; call after `configure` (which never adds one).
    func setSourceBadge(_ text: String?) { sourceBadge.text = text }

    /// Tags a search result with its quality and server; call after
    /// `configure`, which clears them.
    func showVersionTags(for item: MediaItem) { versionTags.show(item: item) }

    /// The badge's text while it shows (tests).
    var sourceBadgeText: String? { sourceBadge.isHidden ? nil : sourceBadge.text }

    /// The title to ask TMDB for when the server's poster is missing or is
    /// a video frame (an item no agent matched). nil for music.
    private var fallbackQuery: ArtworkFallback.Query?
    /// Set once this tile has tried TMDB, so it never loops.
    private var triedFallback = false
    private var isSquareTile = false

    /// Swap in TMDB's poster when the server's is missing, failed, or is a
    /// landscape frame in a portrait slot.
    private func posterNeedsFallback(_ image: UIImage?) -> Bool {
        guard !isSquareTile, !triedFallback, fallbackQuery != nil else { return false }
        guard let image else { return true }
        return image.size.width > image.size.height
    }

    /// A different title (a reconfigured cell) gets its own TMDB try.
    private func setFallbackQuery(_ query: ArtworkFallback.Query?) {
        if query != fallbackQuery { triedFallback = false }
        fallbackQuery = query
    }

    private func loadFallbackPoster(failureIcon: UIImage?) {
        guard let query = fallbackQuery, !triedFallback else { return }
        triedFallback = true
        let original = currentURL
        Task { [weak self] in
            guard let url = await ArtworkFallback.shared.poster(for: query) else { return }
            await MainActor.run {
                guard let self, self.currentURL == original, self.fallbackQuery == query else { return }
                if let original { Self.replacedPosters[original] = url }
                self.loadImage(from: url, failureIcon: failureIcon)
            }
        }
    }

    /// Server posters already found wrong, each with the TMDB poster that
    /// replaced it. A reconfigured or reused cell goes straight to the
    /// replacement: before, it showed the server's frame again and swapped a
    /// second later, which read as the poster jittering on return to a grid.
    private static var replacedPosters: [URL: URL] = [:]

    /// Music tiles are 1:1 square; everything else keeps the 2:3 poster ratio.
    private func setSquare(_ square: Bool) {
        isSquareTile = square
        let height = square ? MediaRowMetrics.musicHeight : posterHeight
        if posterHeightConstraint.constant != height {
            posterWidthConstraint.constant = square ? MediaRowMetrics.musicWidth : posterWidth
            posterHeightConstraint.constant = height
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetContent()
    }

    /// Blank glass card for a library-grid slot whose page has not loaded.
    /// A slot flips to a real item through `reconfigureItems` on the same
    /// cell, and back to this on a sort reset, so clear the previous
    /// occupant here rather than assume `prepareForReuse` ran.
    func configurePlaceholder() {
        resetContent()
        placeholderPanel.isHidden = false
    }

    private func resetContent() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = true
        currentURL = nil
        clearArtwork()
        watchedBadge.isHidden = true
        sourceBadge.text = nil
        versionTags.clear()
        cancelSeasonCount()
        fallbackQuery = nil
        triedFallback = false
        caption.configure(title: nil, year: nil)
        failureIcon.isHidden = true
        failureIcon.image = nil
        // A recycled cell must not inherit a prior occupant's stranded focus
        // (enlarged) appearance — clear any leftover scale transform.
        resetStaleFocusAppearance()
    }

    // MARK: - Image load

    /// PlexMetadata path: resolves the failure icon via the full Plex type
    /// switch (including music types) then delegates to the shared loader.
    private func loadImage(from url: URL?, item: PlexMetadata) {
        loadImage(from: url, failureIcon: failureIconImage(for: item))
    }

    /// MediaItem path: resolves the failure icon via MediaKind then delegates.
    private func loadImage(from url: URL?, failureKind: MediaKind) {
        loadImage(from: url, failureIcon: failureIconImage(for: failureKind))
    }

    private func loadImage(from url: URL?, failureIcon: UIImage?) {
        imageLoadTask?.cancel()
        if let url, let replacement = Self.replacedPosters[url] {
            triedFallback = true
            if currentURL == replacement, hasArtwork { hidePlaceholder(); return }
            loadImage(from: replacement, failureIcon: failureIcon)
            return
        }
        guard let url else {
            clearArtwork()
            currentURL = nil
            showPlaceholderFailure(failureIcon)
            loadFallbackPoster(failureIcon: failureIcon)
            return
        }
        if currentURL == url, hasArtwork {
            hidePlaceholder()
            return
        }
        currentURL = url
        // Memory hit paints in this pass, so a tile realized for a carousel
        // exit has artwork to fly to.
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            posterView.image = cached
            hasArtwork = true
            hidePlaceholder()
            if posterNeedsFallback(cached) { loadFallbackPoster(failureIcon: failureIcon) }
            return
        }
        // Glass panel up immediately (covers the bare gray); the load now
        // retries transient failures internally, so the spinner simply rides
        // the single await until the artwork resolves or genuinely fails.
        showPlaceholderLoading()
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
                    self.hidePlaceholder()
                } else {
                    self.clearArtwork()
                    self.showPlaceholderFailure(failureIcon)
                }
                if self.posterNeedsFallback(image) { self.loadFallbackPoster(failureIcon: failureIcon) }
            }
        }
    }

    private func clearArtwork() {
        posterView.image = Self.blankArtwork
        hasArtwork = false
    }

    /// Glass panel + (delayed) spinner while the artwork loads/retries.
    private func showPlaceholderLoading() {
        placeholderPanel.isHidden = false
        failureIcon.isHidden = true
        // Delay the spinner so a fast cache hit doesn't flash it on scroll.
        cancelSpinnerDelay()
        spinnerDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.placeholderPanel.isHidden, !self.hasArtwork {
                self.loadingSpinner.startAnimating()
            }
        }
    }

    /// Glass panel + faint type icon after a genuine (post-retry) failure.
    private func showPlaceholderFailure(_ icon: UIImage?) {
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = false
        failureIcon.image = icon
        failureIcon.isHidden = false
    }

    /// Artwork resolved — tear the placeholder down.
    private func hidePlaceholder() {
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = true
        failureIcon.isHidden = true
    }

    private func cancelSpinnerDelay() {
        spinnerDelayTask?.cancel()
        spinnerDelayTask = nil
    }

    /// Full Plex-type failure icon switch, including music types.
    /// Mirror of SwiftUI `MediaPosterCard.iconForType` (all types).
    private func failureIconImage(for item: PlexMetadata) -> UIImage? {
        let name: String
        switch item.type {
        case "movie":   name = "film"
        case "show":    name = "tv"
        case "season":  name = "number.square"
        case "episode": name = "play.rectangle"
        case "artist":  name = "music.mic"
        case "album":   name = "square.stack"
        case "track":   name = "music.note"
        default:        name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    /// MediaItem failure icon — maps MediaKind to a system image name.
    private func failureIconImage(for kind: MediaKind) -> UIImage? {
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

    private func posterURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // Episodes prefer the show (grandparent) thumb so Recently-Added
        // episode rows render show posters, not letterboxed episode stills.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            path = item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    // MARK: - Unwatched-count badge

    private func isAudioItem(_ item: PlexMetadata) -> Bool {
        switch item.type {
        case "album", "artist", "track": return true
        default: return false
        }
    }

    /// A show with unwatched episodes gets the blue count pill (top-right);
    /// nothing else gets a watch indicator on its poster.
    private func configureWatchedBadge(item: PlexMetadata) {
        if !isAudioItem(item), item.type == "show", let leafCount = item.leafCount, leafCount > 0 {
            let unwatched = leafCount - (item.viewedLeafCount ?? 0)
            if unwatched > 0 { showUnwatchedCount(unwatched); return }
        }
        watchedBadge.isHidden = true
    }

    private func configureWatchedBadge(item: MediaItem) {
        if item.kind == .show, let cp = item.childProgress, cp.total > 0, cp.total > cp.played {
            showUnwatchedCount(cp.total - cp.played)
            return
        }
        watchedBadge.isHidden = true
    }

    private func showUnwatchedCount(_ count: Int) {
        watchedBadge.setStyle(.unwatchedCount(count))
        watchedBadge.isHidden = false
    }

    private var seasonsTask: Task<Void, Never>?

    /// Search: a show's tag names its seasons ("3 Seasons") in place of the
    /// unwatched-episode count. Call after `configure`, which clears it.
    func showSeasonCount(for item: MediaItem) {
        seasonsTask?.cancel()
        watchedBadge.isHidden = true
        if let known = TitleSeasons.known(for: item.ref) {
            showSeasons(known)
            return
        }
        let ref = item.ref
        seasonsTask = Task { [weak self] in
            let count = await TitleSeasons.count(for: item)
            guard !Task.isCancelled, let self, self.seasonsRef == ref else { return }
            self.showSeasons(count)
        }
        seasonsRef = ref
    }

    private var seasonsRef: MediaItemRef?

    private func showSeasons(_ count: Int?) {
        guard let count, count > 0 else { return }
        watchedBadge.setStyle(.seasons(count))
        watchedBadge.isHidden = false
    }

    private func cancelSeasonCount() {
        seasonsTask?.cancel()
        seasonsTask = nil
        seasonsRef = nil
    }
}

/// How many seasons a show has, not counting Specials (season 0). Read once
/// per show from its season list and kept for the session.
@MainActor
enum TitleSeasons {
    private static var counts: [MediaItemRef: Int?] = [:]
    private static var inFlight: [MediaItemRef: Task<Int?, Never>] = [:]

    /// `.some(nil)` when the read found nothing; nil before the first read.
    static func known(for ref: MediaItemRef) -> Int?? { counts[ref] }

    static func count(for show: MediaItem) async -> Int? {
        let ref = show.ref
        if let known = counts[ref] { return known }
        if let task = inFlight[ref] { return await task.value }
        let task = Task<Int?, Never> {
            guard let provider = MediaProviderRegistry.shared.provider(for: ref.providerID),
                  let seasons = try? await provider.children(of: ref) else { return nil }
            return seasons.filter { $0.kind == .season && $0.seasonNumber != 0 }.count
        }
        inFlight[ref] = task
        let count = await task.value
        inFlight[ref] = nil
        counts[ref] = .some(count)
        return count
    }
}

// MARK: - Unwatched-count badge

/// Top-trailing tag showing the unwatched-episode count for an in-progress
/// TV show, in the same dark outlined style as the quality and server tags.
/// The fully-watched state is shown by a bottom-left rewatch glyph
/// (`WatchedGlyphView`), Apple-style — not by this badge.
@MainActor
final class PosterWatchedBadge: UIView {
    enum Style {
        case unwatchedCount(Int)
        /// Search's show tiles: "1 Season", "3 Seasons".
        case seasons(Int)
    }

    private let countTag = QualityTagView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        countTag.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countTag)
        NSLayoutConstraint.activate([
            countTag.topAnchor.constraint(equalTo: topAnchor),
            countTag.bottomAnchor.constraint(equalTo: bottomAnchor),
            countTag.leadingAnchor.constraint(equalTo: leadingAnchor),
            countTag.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStyle(_ style: Style) {
        switch style {
        case .unwatchedCount(let count):
            countTag.text = "\(count)"
        case .seasons(let count):
            countTag.text = count == 1 ? "1 Season" : "\(count) Seasons"
        }
    }

    func setFocused(_ focused: Bool) { countTag.setFocused(focused) }
}

extension PosterCell: PreviewSourceTile {
    var previewArtworkView: UIView { overlayContainer }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { hasArtwork }
}

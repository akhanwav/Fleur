// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCell.swift
//  Rivulet
//
//  Continue Watching tile, a clone of the Apple TV app's Up Next card,
//  sized by MediaRowMetrics:
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
    private let infoBar = MediaProgressInfoBar()
    /// The version that would play ("4K DV"), bottom-trailing on the card.
    private let qualityTag = QualityTagView()
    /// The card's server ("Alpha"), beside the quality while the row mixes servers.
    private let serverTag = QualityTagView()
    private let tags = UIStackView()
    /// The title (an episode: its show) and the time left under the card. The
    /// card carries no title of its own, so this shows whatever Settings → Show
    /// Titles Under Posters says.
    private let caption = PosterCaptionView()

    private var artworkLoadTask: Task<Void, Never>?
    private var currentArtworkURL: URL?
    private var qualityTask: Task<Void, Never>?

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
        contentView.addSubview(caption)
        caption.pin(below: card, artInset: (MediaRowMetrics.cwWidth - MediaRowMetrics.continueWatching.art.width) / 2)
        caption.followsTitleSetting = false
        caption.isHidden = true

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

        // Bottom status row: the play glyph and progress pill. The time left
        // is in the caption, so the row carries no text of its own.
        infoBar.showsInfoText = false
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(infoBar)

        qualityTag.isHidden = true
        serverTag.isHidden = true
        // A long server name gives way before the quality does.
        qualityTag.setTextCompressionResistance(.required)
        serverTag.setTextCompressionResistance(.defaultLow)
        tags.addArrangedSubview(serverTag)
        tags.addArrangedSubview(qualityTag)
        tags.axis = .horizontal
        tags.spacing = 6
        tags.alignment = .center
        tags.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(tags)

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

            // Apple's status row: 14pt from the card's edges.
            infoBar.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: pad),
            infoBar.trailingAnchor.constraint(lessThanOrEqualTo: tags.leadingAnchor, constant: -8),
            infoBar.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -pad),

            tags.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -pad),
            tags.centerYAnchor.constraint(equalTo: infoBar.centerYAnchor)
        ])
    }

    /// The status row's glyph, label and bar fill follow focus, on the focus clock.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        FocusRim.remove(in: card, focused: nowFocused, coordinator: coordinator)
        coordinator.addCoordinatedAnimations({
            self.infoBar.setFocused(nowFocused)
            self.qualityTag.setFocused(nowFocused)
            self.serverTag.setFocused(nowFocused)
        }, completion: nil)
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
        card.contentView.layer.borderColor = UIColor(white: 1, alpha: 0.03).cgColor
        CATransaction.commit()
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        let url = artworkURL(for: item)

        // Status row: play icon + (optional) progress capsule.
        infoBar.configure(item: item)
        let isEpisode = item.type == "episode"
        let text = PosterCaptionView.continueWatchingText(
            title: item.title ?? "", year: item.year,
            show: isEpisode ? item.grandparentTitle : nil,
            season: isEpisode ? item.parentIndex : nil, episode: isEpisode ? item.index : nil,
            offsetSeconds: TimeInterval(item.viewOffset ?? 0) / 1000,
            runtimeSeconds: item.duration.map { TimeInterval($0) / 1000 })
        caption.configure(title: text.title, detail: text.detail)

        // No show or episode background leaves the episode's own still.
        let isEpisodeStill = item.type == "episode" && item.grandparentArt == nil && item.art == nil
        loadArtwork(from: url, fallback: ArtworkFallback.Query(item), isEpisodeStill: isEpisodeStill,
                    failureIcon: failurePlaceholderImage(for: item))
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    /// `knownQuality` is the tag when the caller has the versions already (another
    /// server's copy, which no provider here can look up); nil looks it up.
    /// `serverName` names the card's server; nil shows none.
    func configure(item: MediaItem, knownQuality: String?? = nil, serverName: String? = nil) {
        serverTag.text = serverName
        serverTag.isHidden = serverName == nil
        // Backdrop > thumbnail in landscape orientation.
        let url = item.grandparentArtwork?.backdrop
            ?? item.artwork.backdrop
            ?? item.artwork.thumbnail

        infoBar.configure(item: item)
        let isEpisode = item.kind == .episode
        let text = PosterCaptionView.continueWatchingText(
            title: item.title, year: item.year,
            show: isEpisode ? item.seriesTitle : nil,
            season: isEpisode ? item.seasonNumber : nil, episode: isEpisode ? item.episodeNumber : nil,
            offsetSeconds: item.userState.viewOffset, runtimeSeconds: item.runtime)
        caption.configure(title: text.title, detail: text.detail)
        if let knownQuality {
            showQuality(knownQuality)
        } else {
            loadQuality(for: item)
        }

        let isEpisodeStill = isEpisode && item.grandparentArtwork?.backdrop == nil && item.artwork.backdrop == nil
        // An episode's fallback is its show's; the shared query covers movies and shows only.
        let fallback: ArtworkFallback.Query? = isEpisode
            ? item.seriesTitle.map { ArtworkFallback.Query(tmdbId: nil, isMovie: false, title: $0, year: nil) }
            : (item.isMetadataOnly ? nil : ArtworkFallback.Query(item))
        loadArtwork(from: url, fallback: fallback, isEpisodeStill: isEpisodeStill,
                    failureIcon: failurePlaceholderImage(for: item.kind))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentArtworkURL = nil
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true
        qualityTask?.cancel()
        qualityTask = nil
        qualityTag.isHidden = true
        serverTag.isHidden = true
        infoBar.reset()
        caption.configure(title: nil, detail: nil)
    }

    // MARK: - Quality

    private func showQuality(_ label: String?) {
        qualityTask?.cancel()
        qualityTask = nil
        qualityTag.text = label
        qualityTag.isHidden = label == nil
    }

    /// The tag for the version this card would play, fetched once per title.
    private func loadQuality(for item: MediaItem) {
        if let known = TitleQuality.known(for: item.ref) {
            showQuality(known)
            return
        }
        showQuality(nil)
        qualityTask = Task { [weak self] in
            let label = await TitleQuality.label(for: item)
            guard !Task.isCancelled, let self else { return }
            self.qualityTag.text = label
            self.qualityTag.isHidden = label == nil
        }
    }

    // MARK: - Artwork

    /// `fallback` names the title on TMDB for a card whose server image is a
    /// video frame or a bare episode still (`ContinueWatchingArtwork`).
    private func loadArtwork(from url: URL?, fallback: ArtworkFallback.Query?, isEpisodeStill: Bool,
                             failureIcon: UIImage?) {
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
        let knownSource = ContinueWatchingArtwork.knownSource(for: url)
        if let knownSource,
           let built = ContinueWatchingCardCompositor.cached(.card, for: knownSource, geometry: geometry, scale: scale) {
            artworkImageView.image = built
            placeholderView.isHidden = true
            return
        }
        artworkImageView.image = nil
        placeholderView.isHidden = false
        placeholderIcon.isHidden = true  // hidden during loading
        let key = url.absoluteString as AnyHashable
        artworkLoadTask = Task { [weak self] in
            let source = await ContinueWatchingArtwork.source(for: url, fallback: fallback,
                                                              isEpisodeStill: isEpisodeStill)
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ContinueWatchingCardCompositor.image(.card, for: source, geometry: geometry, scale: scale)
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

// Info bar moved to `Rivulet/Views/Media/UIKit/Cells/MediaProgressInfoBar.swift`
// for reuse by PosterCell (in-progress items in Recently Added /
// Personalized Recommendations rows render the same composition).

extension ContinueWatchingCell: PreviewSourceTile {
    var previewArtworkView: UIView { card.contentView }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { artworkImageView.image != nil }
}

/// The image a Continue Watching card is built from, when the server's would
/// be a raw picture of the video: a background Plex cut from the file (it keeps
/// the letterbox, `ArtworkFallback.looksLikeVideoFrame`), or an episode whose
/// show has no background, which leaves the episode's still. Both take the
/// title's TMDB backdrop (the show's, for an episode), the way the Apple TV
/// app shows show art there; with none on TMDB the server's image stays.
///
/// Decided once per server URL and remembered, so a reused cell finds the
/// replacement card in the compositor's cache instead of rebuilding from the
/// screenshot first.
@MainActor
enum ContinueWatchingArtwork {
    private static var sources: [URL: URL] = [:]

    /// The decided source for `url`, or nil before the first decision.
    static func knownSource(for url: URL) -> URL? { sources[url] }

    static func source(for url: URL, fallback: ArtworkFallback.Query?, isEpisodeStill: Bool) async -> URL {
        if let known = sources[url] { return known }
        guard let fallback else { return url }
        var replace = isEpisodeStill
        if !replace, let image = await ImageCacheManager.shared.image(for: url) {
            replace = await Task.detached(priority: .utility) {
                ArtworkFallback.looksLikeVideoFrame(image)
            }.value
        }
        let source = replace ? (await ArtworkFallback.shared.backdrop(for: fallback) ?? url) : url
        sources[url] = source
        return source
    }
}

/// The quality of the version a card would play (Continue Watching, and the
/// Search result and Recently Searched tags): the title's
/// best version (`VersionRanking`), worded like the detail page's copies
/// (`DetailCopySelection.qualityText`: "4K DV", "1080p HDR", "1080p"). Hub listings carry no HDR or Dolby Vision
/// detail, so each title's full detail is read once, when its card first
/// shows, and kept for the session.
@MainActor
enum TitleQuality {
    private static var labels: [MediaItemRef: String?] = [:]
    private static var inFlight: [MediaItemRef: Task<String?, Never>] = [:]

    /// The label already read for `ref` (`.some(nil)` when there is none), or
    /// nil before the first read.
    static func known(for ref: MediaItemRef) -> String?? { labels[ref] }

    /// A show or season has no file of its own: its label is the episode
    /// Play would start (`EpisodePicker.resolvePlayTarget`), as Ways to Watch
    /// describes it.
    static func label(for item: MediaItem) async -> String? {
        let ref = item.ref
        if let known = labels[ref] { return known }
        if let task = inFlight[ref] { return await task.value }
        let task = Task<String?, Never> {
            guard let provider = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return nil }
            var target = ref
            if item.kind == .show || item.kind == .season {
                guard let episode = await EpisodePicker.resolvePlayTarget(for: item, provider: provider)
                else { return nil }
                target = episode.ref
            }
            guard let detail = try? await provider.fullDetail(for: target) else { return nil }
            return DetailCopySelection.qualityText(VersionRanking.ordered(detail.mediaSources).first)
        }
        inFlight[ref] = task
        let label = await task.value
        inFlight[ref] = nil
        labels[ref] = .some(label)
        return label
    }
}

/// A small outlined tag, the way the Apple TV app marks a format on artwork:
/// half-white text in a thin rounded rule over a soft dark backing, so it reads
/// on a white sky as well as a dark scene, brightening with the card's focus.
@MainActor
final class QualityTagView: UIView {
    private let label = UILabel()
    /// Never truncated: a long `text` gives way first ("Sesa… +2").
    private let suffixLabel = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    var suffix: String? {
        get { suffixLabel.text }
        set {
            suffixLabel.text = newValue.map { " \($0)" }
            suffixLabel.isHidden = newValue == nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.borderWidth = 1
        layer.cornerRadius = 6
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: [label, suffixLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        for part in [label, suffixLabel] {
            part.font = .systemFont(ofSize: 16, weight: .semibold)
        }
        suffixLabel.isHidden = true
        suffixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
        setFocused(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// How readily `text` truncates when tags share too little room: lower
    /// gives way first (a server name before a quality).
    func setTextCompressionResistance(_ priority: UILayoutPriority) {
        label.setContentCompressionResistancePriority(priority, for: .horizontal)
    }

    func setFocused(_ focused: Bool) {
        let color = UIColor.white.withAlphaComponent(focused ? 0.95 : 0.7)
        label.textColor = color
        suffixLabel.textColor = color
        layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.6 : 0.3).cgColor
    }
}

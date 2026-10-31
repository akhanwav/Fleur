// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaDetailChromeView.swift
//  Rivulet
//
//  The shared chrome surface — logo / genre row / description / quality
//  row / action+cast row — used by the carousel cell (`PreviewCardView`,
//  which also backs the standalone detail) and the home hero button row
//  (`HeroButtonRowView`).
//
//  Layout structure:
//
//      ┌─────────────────────────────────────────┐  ← self
//      │ ┌──────────────────┐                    │
//      │ │ metadataBlock    │  (860pt max)       │
//      │ │   logoSlot       │                    │
//      │ │   genreRow       │                    │
//      │ │   descLabel      │                    │
//      │ │   qualityRow     │                    │
//      │ └──────────────────┘                    │
//      │  ↕ 32pt                                 │
//      │ ┌───────────────────────────────────────┤
//      │ │ actionAndCastRow (full width)         │
//      │ │   [Play][Watched][+][i]    Starring … │
//      │ └───────────────────────────────────────┤
//      └─────────────────────────────────────────┘
//
//  The carousel cell anchors this view bottom-leading inside the card,
//  with the card's horizontal insets (118pt) applied to self's leading
//  and trailing anchors. The expanded detail VC anchors it bottom-leading
//  to the screen with the expanded insets (140pt). The chrome view itself
//  is layout-agnostic — it just lays out its own internal stack from the
//  width its host gives it.
//
//  Animation:
//   - The host owns the cascade timer. This view exposes `chromeAlpha`
//     which forwards directly to `self.alpha`.
//   - The vignette is OUTSIDE this view (owned by the host: carousel
//     cell or expanded-detail VC) because the vignette is part of the
//     surrounding hero, not the chrome content.
//
//  Mode:
//   - `.carouselStable` — action row is interaction-disabled (carousel
//     paging owns input). This is the only mode wired up in Iter A.
//   - `.expandedDetail` — action row becomes focus-enabled and tap-wired
//     (Iter B+). Mode is a property so the host can flip it; this view
//     reads it during `applyItem`.
//

import UIKit
import os.log

private let chromeLog = Logger(
    subsystem: "com.rivulet.app",
    category: "MediaDetailChromeView"
)

final class MediaDetailChromeView: UIView {

    /// Action-button sizing shared with the home hero's
    /// `HeroPillButton`/`HeroCircleButton` (see `HeroButtonRowView`) so the
    /// carousel/expanded-detail row matches the hero exactly. The pill width
    /// is a floor: a long title ("Resume S12, E24") grows past it.
    private static let actionButtonHeight: CGFloat = HeroPillButton.buttonHeight
    private static let actionPillWidth: CGFloat = HeroPillButton.pillWidth
    private static let playProgressTrackWidth: CGFloat = 50
    private static let playProgressTrackHeight: CGFloat = 8
    /// Apple's description cap: wider on an episode.
    private static let descriptionMaxWidth: CGFloat = 677
    private static let episodeDescriptionMaxWidth: CGFloat = 860
    private static let captionFont = UIFont.systemFont(ofSize: 25, weight: .medium)
    private static let descriptionFont = UIFont.systemFont(ofSize: 23, weight: .medium)
    private static let rolesLabelAlpha: CGFloat = 0.6

    // MARK: - Public surface

    /// Layout mode — narrows insets, swaps action-row interactivity.
    /// In Iter A only `.carouselStable` is exercised; the structure is in
    /// place for Iter B to flip to `.expandedDetail`.
    enum Mode {
        case carouselStable
        case expandedDetail
    }

    var mode: Mode = .carouselStable {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    /// Current item this chrome is showing. Setting kicks off the
    /// metadata rebuild + async detail fetch.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            guard !isRefreshingWatchState else { return }
            applyItem()
        }
    }

    /// Cascade alpha — forwarded directly to `self.alpha`. The host owns
    /// the timing; this view just exposes a typed knob.
    var chromeAlpha: CGFloat {
        get { alpha }
        set { alpha = newValue }
    }

    /// Action callbacks. In `.carouselStable` mode these are not invoked
    /// (action row is interaction-disabled). Wired in `.expandedDetail`
    /// during Iter B/D.
    var onPlay: (() -> Void)?
    /// Ways to Watch picked a version on this server: the item it belongs
    /// to (a show's Play target episode, else the hero item) and its file.
    /// Copies on other servers play through `RemoteCopyPlayer` directly.
    var onPlayVersion: ((MediaItem, String) -> Void)?
    var onToggleWatchlist: (() -> Void)?
    /// The selected copy's artwork when it is another server's (nil: the
    /// item's own), so the host shows that server's backdrop.
    var onCopyArtwork: ((MediaArtwork?) -> Void)?
    /// The selected copy when it is another server's or library's (nil: the
    /// item's own), so the episode list loads from it too.
    var onCopyChange: ((BelowFoldCollectionView.EpisodeCopy?) -> Void)?
    var onShowFullDescription: ((MediaItemDetail) -> Void)?

    /// The Play pill (rebuilt per item). Exposed so the host cell can point the
    /// focus engine at Play when the detail expands.
    private(set) var playButton: FocusableActionButton?
    /// Preferred focus target for the action row (Play), or nil before detail loads.
    var playFocusable: UIView? { playButton }

    /// Fill width of the Play pill's watch-progress bar, held so the fraction can
    /// be set after the pill is built — on a show/season the bar belongs to the
    /// episode Play resolves to, which only arrives asynchronously. Rebuilt with
    /// the pill.
    private var playProgressFillWidth: NSLayoutConstraint?
    /// The Play pill's title and progress track. Held so `setPlayTarget` can
    /// rewrite them: the pill is built once and only its watch-derived bits change.
    private weak var playTitleLabel: UILabel?
    private weak var playProgressTrack: UIView?
    private var descriptionMaxWidth: NSLayoutConstraint?

    // MARK: - State

    /// Monotonic load token. Bumped on every `applyItem()`; async detail
    /// fetch checks against this on completion and discards stale results.
    /// Prevents wrong metadata from snapping in when item changes quickly.
    private var loadToken: UInt64 = 0

    /// Cached detail, populated by `loadDetail()` when it lands. Used to
    /// repopulate genre + quality rows + cast label with richer fields.
    private var detail: MediaItemDetail?

    // MARK: - Subviews

    /// Outer vertical stack — bottom-leading aligned by the host. Contains
    /// the metadata block + the action+cast row.
    private let chromeStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        // LEADING, not .fill: the metadata block has a ≤860 width cap, and
        // .fill pins both its edges to the stack — an undefined conflict that
        // could snap the block to the trailing edge (far right) when the chrome
        // is wider than 860. Leading-align it deterministically; the action row
        // gets an explicit full-width constraint instead.
        s.alignment = .leading
        s.spacing = 18
        return s
    }()

    /// Inner metadata block — vertical stack, max 860pt wide.
    /// Natural-content height: takes as much vertical space as the logo
    /// slot (126pt) + genre row + description + quality row + spacing.
    /// The outer `chromeStack` settles this block above the action row;
    /// the chrome view itself is anchored from below by the card.
    /// Matches the carousel-stable layout at commit `bc127a9` (the
    /// agreed visual baseline at the start of Iter A).
    private let metadataBlock: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .leading
        s.spacing = 18
        return s
    }()

    /// Logo slot — fixed 126pt tall, bottom-leading aligned. The logo image
    /// (420pt max wide) or the fallback label (600pt max wide) occupies it
    /// depending on whether `artwork.logo` loaded.
    private let logoSlotView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let titleLogoImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let titleFallbackLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 48, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// "Movie · Adventure · Sci-Fi  [TV-14]"
    private let genreRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 6
        s.alignment = .center
        return s
    }()

    /// Italic tagline OR plain overview, up to 4 lines / 677pt wide (860 on
    /// an episode).
    private let descriptionLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = MediaDetailChromeView.descriptionFont
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 4
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// "2023 · 49 min   ⭐ 7.8   [4K] [DV] [5.1]", dimmer than the genre row.
    private let qualityRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 12
        s.alignment = .center
        return s
    }()

    /// Bottom action+cast row. NOT a stack view — using a UIStackView
    /// here was causing the action buttons to flash stretched-wide on
    /// the first layout pass before constraints settled. A plain
    /// UIView with explicit leading/trailing constraints on the two
    /// children gives byte-stable widths from frame zero: action
    /// buttons hug their content on the left, cast label hugs its
    /// content on the right, the gap between is the leftover.
    private let actionAndCastRow: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    /// Left cluster — Play pill + Watched / Watchlist / Info circles.
    private let actionButtonsStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.alignment = .center
        s.spacing = HeroPillButton.rowGap
        return s
    }()

    /// "Starring …" in a 410pt box on the trailing margin, left-aligned, its
    /// bottom on the buttons' bottom. The names are brighter than the label.
    private let castLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = MediaDetailChromeView.captionFont
        l.textColor = .white
        l.numberOfLines = 3
        l.textAlignment = .natural
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MediaDetailChromeView is not Storyboard-backed")
    }

    private func commonInit() {
        copySelection.onChange = { [weak self] in self?.applySelectedCopy() }
        backgroundColor = .clear
        isUserInteractionEnabled = false  // host flips this on for .expandedDetail

        logoSlotView.addSubview(titleLogoImageView)
        logoSlotView.addSubview(titleFallbackLabel)

        addSubview(chromeStack)

        metadataBlock.addArrangedSubview(logoSlotView)
        metadataBlock.addArrangedSubview(genreRow)
        metadataBlock.addArrangedSubview(descriptionLabel)
        metadataBlock.addArrangedSubview(qualityRow)
        chromeStack.addArrangedSubview(metadataBlock)

        // Apple's rhythm: 18 between the text rows, 32 above the buttons.
        chromeStack.setCustomSpacing(32, after: metadataBlock)
        chromeStack.addArrangedSubview(actionAndCastRow)

        // actionAndCastRow is a plain UIView (not a stack). Children
        // are pinned explicitly: actionButtonsStack to leading +
        // centerY, castLabel to trailing + bottom, with a min-gap
        // between. The two compete only over the gap, so neither
        // can stretch beyond its content width.
        actionAndCastRow.addSubview(actionButtonsStack)
        actionAndCastRow.addSubview(castLabel)

        // Hugging is .required so the stack never stretches beyond the sum
        // of its buttons.
        actionButtonsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionButtonsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let descMaxWidth = descriptionLabel.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.descriptionMaxWidth)
        descriptionMaxWidth = descMaxWidth

        let castWidth = castLabel.widthAnchor.constraint(equalToConstant: 410)
        castWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Chrome stack fills self.
            chromeStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: topAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Logo slot: 126pt tall; the image caps at 420 wide, the text
            // title at 600.
            logoSlotView.heightAnchor.constraint(equalToConstant: 126),
            logoSlotView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            titleLogoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            // Logo image: aspectFit, bottom-leading inside the slot.
            // No fixed height — a 500×120 logo renders at 500×120.
            titleLogoImageView.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleLogoImageView.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleLogoImageView.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),
            titleLogoImageView.topAnchor.constraint(greaterThanOrEqualTo: logoSlotView.topAnchor),
            // Cap height at slot height; prefer to fill it. The
            // priority-999 equality lets the inequality + aspect
            // constraints drive height down when an extra-wide asset
            // would push width past the 420pt cap.
            titleLogoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 126),
            {
                let c = titleLogoImageView.heightAnchor.constraint(equalToConstant: 126)
                c.priority = .init(999)
                return c
            }(),

            // Fallback label: bottom-leading inside the slot.
            titleFallbackLabel.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleFallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleFallbackLabel.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),

            descMaxWidth,

            // Metadata block capped at 860pt wide. Block height is
            // natural (content-driven); chromeStack pins it above the
            // action row from below. With .leading alignment it sits at the
            // leading edge at its natural width — no trailing-pin conflict.
            metadataBlock.widthAnchor.constraint(lessThanOrEqualToConstant: Self.episodeDescriptionMaxWidth),

            // The action+cast row spans the full chrome width (the stack is
            // .leading now, so this must be explicit) — buttons leading, cast
            // trailing.
            actionAndCastRow.widthAnchor.constraint(equalTo: chromeStack.widthAnchor),

            // Action buttons pin to leading + centerY of the row.
            actionButtonsStack.leadingAnchor.constraint(equalTo: actionAndCastRow.leadingAnchor),
            actionButtonsStack.centerYAnchor.constraint(equalTo: actionAndCastRow.centerYAnchor),
            actionButtonsStack.topAnchor.constraint(greaterThanOrEqualTo: actionAndCastRow.topAnchor),
            actionButtonsStack.bottomAnchor.constraint(lessThanOrEqualTo: actionAndCastRow.bottomAnchor),

            // Row height derives from the action buttons stack
            // (54pt circle/pill height).
            actionAndCastRow.heightAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.heightAnchor),

            // Cast box: 410pt on the trailing margin, bottom on the buttons'
            // bottom. It may grow upward past the row; nothing sits there.
            castLabel.trailingAnchor.constraint(equalTo: actionAndCastRow.trailingAnchor),
            castLabel.bottomAnchor.constraint(equalTo: actionButtonsStack.bottomAnchor),
            castWidth,

            // Min 10pt gap between buttons and cast box: a very long button
            // row narrows the box, the buttons keep their widths.
            castLabel.leadingAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.trailingAnchor, constant: 10)
        ])

        applyMode()
    }

    // MARK: - Mode

    private func applyMode() {
        switch mode {
        case .carouselStable:
            actionAndCastRow.isUserInteractionEnabled = false
            isUserInteractionEnabled = false
        case .expandedDetail:
            actionAndCastRow.isUserInteractionEnabled = true
            isUserInteractionEnabled = true
        }
    }

    /// Make the action buttons (un)focusable WITHOUT changing mode. Used when the
    /// user enters the below-fold (details): the chrome is faded out, and its
    /// buttons must be non-focusable so focus can't escape UP from the below-fold
    /// primary row into a chrome button (which is the hero → "jumps to carousel").
    func setActionRowFocusable(_ on: Bool) {
        actionAndCastRow.isUserInteractionEnabled = on
    }

    // MARK: - Reset (host calls during cell reuse)

    /// Clears all displayed content and bumps the load token so any
    /// in-flight async work is discarded. Called by `PreviewCardView`'s
    /// `prepareForReuse`.
    func reset() {
        loadToken &+= 1
        item = nil
        detail = nil
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        titleLogoImageView.isHidden = false
        titleFallbackLabel.isHidden = false
        descriptionLabel.text = nil
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        playButton = nil
        castLabel.text = nil
    }

    // MARK: - Apply / load

    /// Repaint only the watch-derived hero bits from a re-fetched copy of the
    /// SAME item (issue #228: the hero kept showing the pre-playback state
    /// after the player dismissed).
    ///
    /// Deliberately NOT `self.item = refreshed`: that `didSet` runs the full
    /// `applyItem()`, which tears down and rebuilds the action row — and the
    /// Play pill is very often the focused view when the player dismisses back
    /// onto the hero. Only the watched glyph and the Play pill's title and
    /// bar depend on watch state, so both are updated in place.
    func refreshWatchState(from refreshed: MediaItem) {
        guard let current = item, current.ref == refreshed.ref else { return }
        // Keep the stored item current so a later toggle/Play reads fresh state.
        isRefreshingWatchState = true
        item = refreshed
        isRefreshingWatchState = false

        heroWatched = refreshed.isWatched
        updateWatchedIcon()
        // Another server's copy was played: re-read every copy (each has its
        // own resume point) and stay on that server (it is now last watched).
        if copySelection.isRemoteSelected {
            copySelection.load(item: refreshed, mainDetail: detail)
            return
        }
        setPlayTarget(refreshed)
        // Shows/seasons: the pill moves to the next unwatched episode.
        resolvePlayTarget(for: refreshed, token: loadToken)
    }

    /// Set while `refreshWatchState` swaps the re-fetched item in, so the
    /// `item` `didSet` skips the full rebuild.
    private var isRefreshingWatchState = false

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken

        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        descriptionLabel.text = nil
        descriptionLabel.attributedText = nil
        resolvedGenres = []
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let item = item else { return }

        descriptionMaxWidth?.constant = item.kind == .episode
            ? Self.episodeDescriptionMaxWidth : Self.descriptionMaxWidth
        rebuildGenreRow(item: item, detail: nil)
        rebuildQualityRow(item: item, detail: nil)
        mainPlayTarget = nil
        rebuildActionButtons(item: item)
        resolvePlayTarget(for: item, token: token)
        // An owned title starts its copies once its detail lands (it names the
        // Plex guid); an unowned one has only other servers' copies.
        copySelection.reset()
        if item.isMetadataOnly { copySelection.load(item: item, mainDetail: nil) }

        // The title as text, never the title logo. An episode or season
        // stands in for its show here, so the words are the show's ("Formula
        // 1", not "Episode 99").
        titleFallbackLabel.text = item.seriesTitle ?? item.title
        titleFallbackLabel.isHidden = false
        titleLogoImageView.isHidden = true
        titleLogoImageView.image = nil

        // Detail fetch — populates richer genre / rating / quality / cast.
        loadDetail(for: item, token: token)
    }

    /// Async fetch of `MediaItemDetail` through the agnostic provider
    /// registry. Tries `MediaProvider` first (Plex), falls back to
    /// `MetadataSource` (TMDB) for catalog-only items.
    private func loadDetail(for item: MediaItem, token: UInt64) {
        Task { [weak self] in
            guard let self, let fetched = await Self.fetchDetail(item.ref) else { return }
            // An episode's own detail has no genres — fall back to the parent
            // show's genres (same as the episode detail page).
            var genres = fetched.genres
            if genres.isEmpty, item.kind == .episode, let showRef = item.grandparentRef,
               let showDetail = await Self.fetchDetail(showRef) {
                genres = showDetail.genres
            }
            await MainActor.run {
                guard self.loadToken == token else { return }
                self.detail = fetched
                self.resolvedGenres = genres
                self.applyDetail(item: item, detail: fetched)
                self.refreshTrackButtons()
            }
        }
    }

    private var resolvedGenres: [String] = []

    /// Resolve the episode Play will start on a show/season card and point the
    /// pill at it ("Play S1, E3"). Uses the same `EpisodePicker.resolvePlayTarget`
    /// the Play button does, so the title can never promise a different episode
    /// than the one that plays.
    private func resolvePlayTarget(for item: MediaItem, token: UInt64) {
        guard item.kind == .show || item.kind == .season else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                  let episode = await EpisodePicker.resolvePlayTarget(for: item, provider: provider),
                  self.loadToken == token
            else { return }
            self.mainPlayTarget = episode
            // The pill names the selected copy's episode: another server's
            // copy has its own next episode.
            if !self.copySelection.isRemoteSelected { self.setPlayTarget(episode) }
            // Its tracks, for the Audio and Subtitles pickers.
            let episodeDetail = await Self.fetchDetail(episode.ref)
            guard self.loadToken == token else { return }
            self.mainPlayTargetDetail = episodeDetail
            self.refreshTrackButtons()
        }
    }

    private static func fetchDetail(_ ref: MediaItemRef) async -> MediaItemDetail? {
        if let provider = await MainActor.run(body: {
            MediaProviderRegistry.shared.provider(for: ref.providerID)
        }) {
            return try? await provider.fullDetail(for: ref)
        }
        if let source = await MainActor.run(body: {
            MetadataSourceRegistry.shared.source(for: ref.providerID)
        }) {
            return try? await source.itemDetail(ref)
        }
        return nil
    }

    /// Re-render the chrome rows + description + cast with newly-loaded
    /// detail fields. Called only when the fetch lands and the load
    /// token still matches.
    private func applyDetail(item: MediaItem, detail: MediaItemDetail) {
        rebuildGenreRow(item: item, detail: detail)
        rebuildQualityRow(item: item, detail: detail)
        if let s = item.seasonNumber, let e = item.episodeNumber,
           let overview = detail.item.overview, !overview.isEmpty {
            // Episode: bold "S1, E1:" prefix before the synopsis.
            let color = UIColor.white.withAlphaComponent(0.85)
            let attr = NSMutableAttributedString(string: "S\(s), E\(e): ", attributes: [
                .font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: color])
            attr.append(NSAttributedString(string: overview, attributes: [
                .font: Self.descriptionFont, .foregroundColor: color]))
            descriptionLabel.attributedText = attr
        } else if let tagline = detail.tagline, !tagline.isEmpty {
            descriptionLabel.text = tagline
            descriptionLabel.font = UIFont.italicSystemFont(ofSize: 23)
        } else if let overview = detail.item.overview, !overview.isEmpty {
            descriptionLabel.text = overview
            descriptionLabel.font = Self.descriptionFont
        }
        let topCast = detail.cast.prefix(3).map { $0.name }
        if !topCast.isEmpty {
            let attr = NSMutableAttributedString(string: "Starring ", attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(Self.rolesLabelAlpha)])
            attr.append(NSAttributedString(string: topCast.joined(separator: ", ")))
            castLabel.attributedText = attr
        } else {
            castLabel.attributedText = nil
        }
        copySelection.load(item: item, mainDetail: detail)
        addTrailerButton(detail)
    }

    /// The server copies of this title and which one the page is on (see
    /// `DetailCopySelection`). Play, the resume bar, the quality badges and
    /// the Info popup all follow the selected copy.
    private let copySelection = DetailCopySelection()
    /// A show's or season's Play target on the main server, kept so the pill
    /// can go back to it after another server's copy was selected.
    private var mainPlayTarget: MediaItem?
    /// That episode's detail: the tracks a show page's pickers list.
    private var mainPlayTargetDetail: MediaItemDetail?

    /// Switch the page to another copy (On Your Servers), by
    /// `DetailCopy.id`. No-op when the page has no such copy.
    func selectCopy(copyID: String) {
        copySelection.select(copyID: copyID)
    }

    /// Repaint everything tied to the selected copy.
    private func applySelectedCopy() {
        guard let item else { return }
        guard let copy = copySelection.selected else {
            // An unowned title no server holds still gets Ways to Watch,
            // which says so, once the lookup has answered.
            if item.isMetadataOnly, copySelection.hasLookedUp { insertWaysToWatchButtonIfNeeded(force: true) }
            return
        }
        if item.isMetadataOnly { insertPlayPillIfNeeded(item: item) }
        if copy.isMainServer {
            setPlayTarget(mainPlayTarget ?? copy.item)
        } else {
            setPlayTarget(copy.playTarget ?? copy.item)
        }
        let source = copy.isSeries
            ? VersionRanking.ordered(copy.playTargetDetail?.mediaSources ?? []).first
            : copySelection.selectedDetail?.primarySource
        rebuildQualityRow(item: item, detail: copySelection.selectedDetail ?? detail, source: source)
        insertWaysToWatchButtonIfNeeded()
        refreshTrackButtons()
        // Another server's copy brings its own (possibly custom) artwork; an
        // unowned page's copy is the only server art it has.
        onCopyArtwork?(copy.isMainServer ? nil : copy.item.artwork)
        onCopyChange?(copy.isMainServer ? nil : copy.remote.map { remote in
            BelowFoldCollectionView.EpisodeCopy(
                original: item.ref, show: copy.item, machineId: copy.machineId,
                serverName: copy.serverName, serverURL: remote.serverURL, token: remote.token)
        })
    }

    /// Play the selected copy: another server's through `RemoteCopyPlayer`
    /// (its own resume prompt), the main server's through the host, with the
    /// picked version when there is one.
    private func playSelectedCopy() {
        guard let item else { return }
        if copySelection.isRemoteSelected {
            guard let host = hostViewController else { return }
            copySelection.playRemote(from: host)
        } else if let mediaID = copySelection.selectedMediaID, item.kind == .movie || item.kind == .episode {
            onPlayVersion?(item, mediaID)
        } else {
            onPlay?()
        }
    }

    /// An unowned title another server holds gains a Play pill in front.
    private func insertPlayPillIfNeeded(item: MediaItem) {
        guard !actionButtonsStack.arrangedSubviews.contains(where: { $0 === playPill }) else { return }
        let play = makePlayPill(item: item)
        play.onPrimaryAction = { [weak self] in self?.playSelectedCopy() }
        actionButtonsStack.insertArrangedSubview(play, at: 0)
        playPill = play
        playButton = play
    }

    private weak var playPill: FocusableActionButton?

    /// Ways to Watch button, last in the row, once the title has a copy to list:
    /// every owned title (one copy included, so its server and quality can
    /// always be read) and any unowned one another server holds.
    private func insertWaysToWatchButtonIfNeeded(force: Bool = false) {
        guard force || !copySelection.copies.isEmpty, versionsButton == nil else { return }
        let button = makeCircleButton(systemImage: "square.stack", caption: "Ways to Watch")
        button.onPrimaryAction = { [weak self, weak button] in
            guard let self, let button, let host = self.hostViewController else { return }
            self.copySelection.present(from: host, sourceFrame: button.convert(button.bounds, to: nil))
        }
        actionButtonsStack.addArrangedSubview(button)
        versionsButton = button
    }

    /// Trailer button for metadata-only items (TMDB's YouTube trailer, opened
    /// in the YouTube app) — hidden entirely when there's no trailer, or when
    /// this device has nothing registered to open it.
    private func addTrailerButton(_ detail: MediaItemDetail) {
        guard let url = detail.externalTrailerURL, UIApplication.shared.canOpenURL(url) else { return }
        let trailer = makeCircleButton(systemImage: "play.rectangle", caption: "Trailer")
        trailer.onPrimaryAction = {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        // Ways to Watch stays last.
        if let versions = versionsButton, let index = actionButtonsStack.arrangedSubviews.firstIndex(of: versions) {
            actionButtonsStack.insertArrangedSubview(trailer, at: index)
        } else {
            actionButtonsStack.addArrangedSubview(trailer)
        }
    }

    // MARK: - Row builders

    private func rebuildActionButtons(item: MediaItem) {
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Metadata-only items (TMDB/Discover, unmatched watchlist entries)
        // have no playback route — no provider is registered for their ref,
        // so Play / Watched / provider-watchlist would all silently no-op.
        // Their primary action is the Watchlist toggle instead.
        if item.isMetadataOnly {
            rebuildMetadataOnlyActions(item: item)
            return
        }

        // Carousel-stable button set (agreed in perf-spike commits up to
        // bc127a9): Play pill + Watched + Watchlist + Info. The SwiftUI
        // source has a wider set (Trailer, Audio, Subs) that's gated by
        // detail content — we don't surface those in the carousel.
        let play = makePlayPill(item: item)
        play.onPrimaryAction = { [weak self] in self?.playSelectedCopy() }
        playPill = play
        // Movie/episode: the item's own state. Show/season: reads "Play" until
        // the Play target resolves async in `resolvePlayTarget`.
        setPlayTarget(item)

        let watched = makeCircleButton(systemImage: "checkmark", caption: "Watched")
        watchedButton = watched
        heroWatched = item.isWatched
        updateWatchedIcon()
        watched.onPrimaryAction = { [weak self] in self?.toggleWatched(item) }

        let watchlist = makeCircleButton(systemImage: "plus", caption: "Watchlist")     // add to watchlist
        watchlistButton = watchlist
        heroOnWatchlist = false
        updateWatchlistIcon()
        let ref = item.ref
        Task { [weak self] in
            guard let p = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
            let on = await p.isOnWatchlist(ref)
            await MainActor.run { self?.heroOnWatchlist = on; self?.updateWatchlistIcon() }
        }
        watchlist.onPrimaryAction = { [weak self] in self?.toggleWatchlist(item) }

        let info = makeCircleButton(systemImage: "text.page", caption: "Info")     // open details popup
        infoButton = info
        info.onPrimaryAction = { [weak self] in
            guard let self, let detail = self.copySelection.selectedDetail ?? self.detail else { return }
            self.onShowFullDescription?(detail)
        }

        actionButtonsStack.addArrangedSubview(play)
        actionButtonsStack.addArrangedSubview(watched)
        // Jellyfin has no watchlist: its add throws, so the button would flip
        // and snap back. Nil provider keeps today's behaviour.
        if MediaProviderRegistry.shared.provider(for: item.ref.providerID)?.supportsWatchlist ?? true {
            actionButtonsStack.addArrangedSubview(watchlist)
        }
        actionButtonsStack.addArrangedSubview(info)
        addTrackButtons(item: item)
        // An episode's Watched acts on the episode alone; the whole show is
        // marked from the show's own page, which this opens.
        if item.kind == .episode, let showRef = item.grandparentRef, !showRef.itemID.isEmpty {
            let goToShow = makeCircleButton(systemImage: "tv", caption: "Go to Show")
            goToShow.onPrimaryAction = { [weak self] in
                guard let self, let host = self.hostViewController else { return }
                PreviewCarouselViewController.openShowDetail(showRef, from: host)
            }
            actionButtonsStack.addArrangedSubview(goToShow)
        }
        playButton = play
    }

    // MARK: - Audio and Subtitles

    private weak var audioButton: FocusableActionButton?
    private weak var subtitlesButton: FocusableActionButton?

    /// The file the Audio and Subtitles pickers describe, and the item it
    /// belongs to on that copy's server.
    private struct TrackTarget {
        let source: MediaSource
        let playable: MediaItem
        let copy: DetailCopy?
    }

    /// Audio and Subtitles, right of Info, on a Plex movie, show or episode.
    /// Hidden until the selected copy's tracks are known.
    private func addTrackButtons(item: MediaItem) {
        guard item.ref.isPlex, [.movie, .show, .episode].contains(item.kind) else { return }
        let audio = makeCircleButton(systemImage: "speaker.wave.2", caption: "Audio")
        audio.onPrimaryAction = { [weak self, weak audio] in self?.presentAudioPicker(from: audio) }
        let subtitles = makeCircleButton(systemImage: "captions.bubble", caption: "Subtitles")
        subtitles.onPrimaryAction = { [weak self, weak subtitles] in self?.presentSubtitlePicker(from: subtitles) }
        audioButton = audio
        subtitlesButton = subtitles
        actionButtonsStack.addArrangedSubview(audio)
        actionButtonsStack.addArrangedSubview(subtitles)
        refreshTrackButtons()
    }

    /// The selected copy's picked version (best first otherwise); on a show
    /// page, the episode Play would start on that copy.
    private func trackTarget() -> TrackTarget? {
        guard let item else { return nil }
        let copy = copySelection.selected
        if item.kind == .show {
            let remote = copy.map { !$0.isMainServer } ?? false
            let detail = remote ? copy?.playTargetDetail : (mainPlayTargetDetail ?? copy?.playTargetDetail)
            let playable = remote ? copy?.playTarget : (mainPlayTarget ?? copy?.playTarget)
            guard let detail, let playable,
                  let source = VersionRanking.ordered(detail.mediaSources).first else { return nil }
            return TrackTarget(source: source, playable: playable, copy: copy)
        }
        let detail = copySelection.selectedDetail ?? detail
        let sources = copySelection.selectedDetail != nil
            ? (detail?.mediaSources ?? []) : VersionRanking.ordered(detail?.mediaSources ?? [])
        guard let source = sources.first else { return nil }
        return TrackTarget(source: source, playable: copy?.item ?? item, copy: copy)
    }

    /// Where a choice is kept: the movie's or episode's guid, or the show's
    /// for every episode of it.
    private var trackChoiceKey: String? {
        TitleTrackChoices.key(guid: (copySelection.selectedDetail ?? detail)?.plexGuid ?? detail?.plexGuid)
    }

    private func refreshTrackButtons() {
        guard let audioButton, let subtitlesButton else { return }
        guard let target = trackTarget() else {
            audioButton.isHidden = true
            subtitlesButton.isHidden = true
            return
        }
        let choice = TitleTrackChoices.choice(for: trackChoiceKey)
        audioButton.isHidden = target.source.audioTracks.isEmpty
        audioButton.focusCaption = Self.currentAudio(in: target.source, choice: choice).map(TrackLabels.audioButton) ?? "Audio"
        subtitlesButton.isHidden = false
        subtitlesButton.focusCaption = Self.currentSubtitle(in: target.source, choice: choice)
            .map(TrackLabels.subtitleButton) ?? "Off"
    }

    /// The track that will play: the saved choice, else Plex's selection,
    /// else the file's default, else the first.
    private static func currentAudio(in source: MediaSource, choice: TitleTrackChoice?) -> AudioTrack? {
        let tracks = source.audioTracks
        if let intent = choice?.audio, let match = TitleTrackMatch.audio(intent, in: tracks) { return match }
        return tracks.first(where: \.isSelected) ?? tracks.first(where: \.isDefault) ?? tracks.first
    }

    /// The subtitles that will play (nil: off): the saved choice, else Plex's
    /// own selection, else Settings → Playback → Default Subtitles.
    private static func currentSubtitle(in source: MediaSource, choice: TitleTrackChoice?) -> SubtitleTrack? {
        let tracks = source.subtitleTracks
        if let intent = choice?.subtitle {
            if intent == .off { return nil }
            if let match = TitleTrackMatch.subtitle(intent, in: tracks) { return match }
        }
        if let selected = tracks.first(where: { $0.isSelected && !$0.isForced && !$0.isDefault }) { return selected }
        switch DefaultSubtitles.current {
        case .english: return EnglishSubtitleDefault.pick(tracks)
        case .off: return nil
        case .lastUsed:
            guard let intent = TrackIntentStore.subtitleIntent, intent != .off else { return nil }
            return TitleTrackMatch.subtitle(intent, in: tracks)
        }
    }

    private func presentAudioPicker(from button: UIView?) {
        guard let target = trackTarget(), let host = hostViewController else { return }
        let current = Self.currentAudio(in: target.source, choice: TitleTrackChoices.choice(for: trackChoiceKey))
        let tracks = target.source.audioTracks
        let titles = TrackLabels.distinct(tracks.map(TrackLabels.audioRow), titles: tracks.map(\.title))
        let rows = zip(tracks, titles).map { track, title in
            TileMenuAction(title: title, systemImage: track.id == current?.id ? "checkmark.circle.fill" : "circle",
                           id: track.id) { [weak self] in
                self?.chooseAudio(track, target: target)
            }
        }
        present(rows, title: "Audio", focusing: current?.id, from: button, host: host)
    }

    private func presentSubtitlePicker(from button: UIView?) {
        guard let target = trackTarget(), let host = hostViewController else { return }
        let current = Self.currentSubtitle(in: target.source, choice: TitleTrackChoices.choice(for: trackChoiceKey))
        let off = TileMenuAction(title: "Off", systemImage: current == nil ? "checkmark.circle.fill" : "circle",
                                 id: "off") { [weak self] in self?.chooseSubtitle(nil, target: target) }
        let tracks = target.source.subtitleTracks
        let titles = TrackLabels.distinct(tracks.map(TrackLabels.subtitleRow), titles: tracks.map(\.title))
        let rows = zip(tracks, titles).map { track, title in
            TileMenuAction(title: title, systemImage: track.id == current?.id ? "checkmark.circle.fill" : "circle",
                           id: track.id) { [weak self] in
                self?.chooseSubtitle(track, target: target)
            }
        }
        present([off] + rows, title: "Subtitles", focusing: current?.id ?? "off", from: button, host: host)
    }

    private func present(_ rows: [TileMenuAction], title: String, focusing key: String?,
                         from button: UIView?, host: UIViewController) {
        let frame = button.map { $0.convert($0.bounds, to: nil) }
        let popup = TileMenuPopupViewController(sections: [rows], sourceFrame: frame, header: TileMenuHeader(title: title))
        popup.initialFocusKey = key
        host.topmostPresented.present(popup, animated: false)
    }

    /// Kept for the title, and sent to Plex for this file so other clients
    /// follow it. It applies when Play is pressed (`UniversalPlayerViewModel`).
    private func chooseAudio(_ track: AudioTrack, target: TrackTarget) {
        if let key = trackChoiceKey { TitleTrackChoices.setAudio(AudioIntent(from: track), for: key) }
        refreshTrackButtons()
        let provider = Self.provider(for: target)
        Task { try? await provider?.setSelectedAudioTrack(track.id, source: target.source.id, of: target.playable.ref) }
    }

    private func chooseSubtitle(_ track: SubtitleTrack?, target: TrackTarget) {
        if let key = trackChoiceKey {
            TitleTrackChoices.setSubtitle(track.map(SubtitleIntent.init(from:)) ?? .off, for: key)
        }
        refreshTrackButtons()
        let provider = Self.provider(for: target)
        Task { try? await provider?.setSelectedSubtitleTrack(track?.id, source: target.source.id, of: target.playable.ref) }
    }

    /// The copy's own server: the registered provider, or one made for another
    /// server's copy from its address and token.
    private static func provider(for target: TrackTarget) -> (any MediaProvider)? {
        if let provider = MediaProviderRegistry.shared.provider(for: target.playable.ref.providerID) { return provider }
        guard let copy = target.copy, let remote = copy.remote else { return nil }
        return PlexProvider(machineIdentifier: copy.machineId, displayName: copy.serverName,
                            serverURL: remote.serverURL, authToken: remote.token)
    }

    private var hostViewController: UIViewController? {
        sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
    }

    /// Metadata-only (TMDB) action row: Watchlist pill + Info. The pill
    /// toggles the Plex Discover watchlist via the tmdb guid (the provider
    /// registry has no entry for TMDB refs). No Watched circle — external
    /// items carry no watch state.
    private func rebuildMetadataOnlyActions(item: MediaItem) {
        let pill = makeWatchlistPill(item: item)

        let info = makeCircleButton(systemImage: "text.page", caption: "Info")
        metadataInfoButton = info
        info.onPrimaryAction = { [weak self] in
            guard let self, let detail = self.copySelection.selectedDetail ?? self.detail else { return }
            self.onShowFullDescription?(detail)
        }

        actionButtonsStack.addArrangedSubview(pill)
        actionButtonsStack.addArrangedSubview(info)
        // The pill is the row's primary focus target (playFocusable feeds
        // the carousel's land-on-primary routing).
        playButton = pill
    }

    /// Watchlist pill — same hardcoded geometry as the Play pill
    /// (Self.actionPillWidth × Self.actionButtonHeight) with bookmark
    /// icon + state-reflecting label.
    private func makeWatchlistPill(item: MediaItem) -> FocusableActionButton {
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = Self.actionButtonHeight / 2
        pill.layer.cornerCurve = .continuous

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = HeroPillButton.titleFont
        label.textColor = .white

        let contentStack = UIStackView(arrangedSubviews: [icon, label])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = HeroPillButton.iconGap

        pill.addSubview(contentStack)
        NSLayoutConstraint.activate(Self.pillConstraints(pill, content: contentStack) + [
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24)
        ])
        pill.invertOnFocus = [icon, label]

        guard let tmdbID = item.tmdbID else {
            icon.image = UIImage(systemName: "bookmark")
            label.text = "Watchlist"
            return pill
        }
        let guid = "tmdb://\(tmdbID)"

        func render() {
            let isOn = PlexWatchlistService.shared.contains(guid: guid)
                || PlexWatchlistService.shared.contains(tmdbId: tmdbID)
            icon.image = UIImage(systemName: isOn ? "bookmark.fill" : "bookmark")
            label.text = "Watchlist"
        }
        render()

        pill.onPrimaryAction = { [weak pill] in
            Task { @MainActor in
                let service = PlexWatchlistService.shared
                if service.contains(guid: guid) || service.contains(tmdbId: tmdbID) {
                    await service.remove(guid: guid)
                } else {
                    let entry = PlexWatchlistItem(
                        id: guid,
                        title: item.title,
                        year: item.year,
                        type: item.kind == .movie ? .movie : .show,
                        posterURL: item.artwork.poster,
                        guids: [guid]
                    )
                    await service.add(guid: guid, item: entry)
                }
                _ = pill  // keep the pill alive through the await for render
                render()
            }
        }
        return pill
    }

    private weak var watchedButton: FocusableActionButton?
    private weak var watchlistButton: FocusableActionButton?
    private weak var infoButton: FocusableActionButton?
    private weak var versionsButton: FocusableActionButton?
    private weak var metadataInfoButton: FocusableActionButton?
    private var heroWatched = false
    private var heroOnWatchlist = false

    private func toggleWatched(_ item: MediaItem) {
        // The stored item, not the one captured at build: a refresh since then
        // carries the show's current episode counts.
        let current = self.item ?? item
        if current.kind == .show { confirmShowWatchChange(current); return }
        setWatched(!heroWatched, current)
    }

    /// A show's Watched changes every episode at once, so it asks first and
    /// says how many episodes are already watched.
    private func confirmShowWatchChange(_ show: MediaItem) {
        guard let host = hostViewController else { return }
        let prompt = ShowWatchPrompt(progress: show.childProgress)
        let alert = UIAlertController(title: show.title, message: prompt.message, preferredStyle: .alert)
        for choice in prompt.choices {
            alert.addAction(UIAlertAction(title: choice.title, style: .default) { [weak self] _ in
                self?.setWatched(choice.markWatched, show)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        host.present(alert, animated: true)
    }

    private func setWatched(_ target: Bool, _ item: MediaItem) {
        heroWatched = target
        updateWatchedIcon()
        Task {
            guard let p = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
            if target { try? await p.markPlayed(item.ref) } else { try? await p.markUnplayed(item.ref) }
            // Issue #270: the glyph was the only thing that moved. This is the
            // same repaint the player posts on dismissal, so the hero's Next Up
            // line, the episode rail, and Home's Continue Watching row all
            // re-read the state this toggle just changed.
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        }
    }

    private func toggleWatchlist(_ item: MediaItem) {
        heroOnWatchlist.toggle()
        updateWatchlistIcon()
        let target = heroOnWatchlist
        Task { [weak self] in
            guard let p = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
            do {
                if target { try await p.addToWatchlist(item.ref) } else { try await p.removeFromWatchlist(item.ref) }
            } catch {
                // The optimistic flip above was a promise the server didn't keep
                // (unmatched item, no Discover match). Put the icon back rather
                // than leave it claiming a state that won't survive reopening.
                await MainActor.run {
                    guard let self else { return }
                    self.heroOnWatchlist = !target
                    self.updateWatchlistIcon()
                }
            }
        }
    }

    // Distinct active glyphs so watched ≠ watchlist when both are on.
    private func updateWatchedIcon() {
        Self.setCircleIcon(watchedButton, heroWatched ? "checkmark.circle.fill" : "checkmark")
    }
    private func updateWatchlistIcon() {
        Self.setCircleIcon(watchlistButton, heroOnWatchlist ? "bookmark.fill" : "plus")
    }
    static func setCircleIcon(_ button: FocusableActionButton?, _ name: String) {
        (button?.subviews.compactMap { $0 as? UIImageView }.first)?.image = UIImage(systemName: name)
    }

    private func rebuildGenreRow(item: MediaItem, detail: MediaItemDetail?) {
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // resolvedGenres includes the parent show's genres for episodes (an
        // episode's own detail has none).
        let parts = ([Self.kindLabel(item.kind)] + resolvedGenres.prefix(2)).filter { !$0.isEmpty }
        if !parts.isEmpty {
            genreRow.addArrangedSubview(Self.makeCaptionLabel(parts.joined(separator: " · "), alpha: 1))
        }

        if let contentRating = detail?.contentRating, !contentRating.isEmpty {
            genreRow.addArrangedSubview(Self.makeBadge(contentRating, alpha: 1))
        }
    }

    /// Apple dims the whole metadata row, text and badges alike.
    private static let qualityRowAlpha: CGFloat = 0.75

    /// `source` is the file the technical badges describe: the selected
    /// copy's (a show's: the episode Play would start on that copy), else the
    /// detail's own first file.
    private func rebuildQualityRow(item: MediaItem, detail: MediaItemDetail?, source: MediaSource? = nil) {
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var parts: [String] = []
        if item.kind == .episode,
           let raw = item.releaseDate,
           let formatted = Self.formattedAirDate(raw) {
            parts.append(formatted)
        } else if let year = item.year {
            parts.append(String(year))
        }
        // A movie whose copies are different cuts runs as long as the selected
        // file, and names its cut in a box beside the quality instead.
        let cutRuntime = item.kind == .movie ? copySelection.selectedCutRuntime : nil
        let cutName = cutRuntime == nil ? nil : copySelection.selectedCutName
        if let runtime = cutRuntime ?? item.runtime, runtime > 0 { parts.append(Self.formatRuntime(runtime)) }
        if cutRuntime == nil, let edition = detail?.item.editionTitle ?? item.editionTitle, !edition.isEmpty {
            parts.append(edition)
        }

        if !parts.isEmpty {
            qualityRow.addArrangedSubview(
                Self.makeCaptionLabel(parts.joined(separator: " · "), alpha: Self.qualityRowAlpha))
        }

        if let rating = detail?.rating {
            let ratingLabel = Self.makeCaptionLabel(rating.badgeText, alpha: Self.qualityRowAlpha)
            let starStack = UIStackView(arrangedSubviews: [ratingLabel])
            if rating.showsStar {
                let star = UIImageView(image: UIImage(systemName: "star.fill"))
                star.tintColor = .systemYellow
                star.contentMode = .scaleAspectFit
                star.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    star.widthAnchor.constraint(equalToConstant: 20),
                    star.heightAnchor.constraint(equalToConstant: 20)
                ])
                starStack.insertArrangedSubview(star, at: 0)
            }
            starStack.axis = .horizontal
            starStack.spacing = 4
            starStack.alignment = .center
            qualityRow.addArrangedSubview(starStack)
        }

        let technical = source ?? detail?.primarySource
        if let badges = technical?.qualityBadges(), !badges.isEmpty {
            for badge in badges {
                qualityRow.addArrangedSubview(Self.makeBadge(badge, alpha: Self.qualityRowAlpha))
            }
        }
        if let cutName { qualityRow.addArrangedSubview(Self.makeBadge(cutName, alpha: Self.qualityRowAlpha)) }
        // The video stream's own bitrate, else the file's.
        if let bitrate = technical.flatMap({ $0.videoTracks.first?.bitrate ?? $0.bitrate }), bitrate > 0 {
            qualityRow.addArrangedSubview(
                Self.makeCaptionLabel(PlayerInfoSheetStyle.bitrate(bitrate), alpha: Self.qualityRowAlpha))
        }
        // The server the page's copy is on, following Ways to Watch.
        let server = copySelection.selected?.serverName
            ?? PlexItemServer.name(for: item.ref)
        if let server, !server.isEmpty {
            qualityRow.addArrangedSubview(Self.makeBadge(server, alpha: Self.qualityRowAlpha))
        }
    }

    // MARK: - Factories

    private func makePlayPill(item: MediaItem) -> FocusableActionButton {
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = Self.actionButtonHeight / 2
        pill.layer.cornerCurve = .continuous

        let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = HeroPillButton.titleFont
        titleLabel.textColor = .white
        // Text is set by `setPlayTarget`, called right after this returns (and
        // again on every refresh) — building it here too would just be a second
        // rule to keep in sync.
        playTitleLabel = titleLabel

        let progressTrack = UIView()
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        progressTrack.layer.cornerRadius = Self.playProgressTrackHeight / 2
        progressTrack.clipsToBounds = true
        playProgressTrack = progressTrack

        let progressFill = UIView()
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressTrack.addSubview(progressFill)
        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        playProgressFillWidth = fillWidth

        // Content is centered in the pill (not leading-anchored) so a pill
        // wider than its content doesn't leave it stranded on the left.
        let contentStack = UIStackView(arrangedSubviews: [playIcon, progressTrack, titleLabel])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = HeroPillButton.iconGap

        pill.addSubview(contentStack)

        NSLayoutConstraint.activate(Self.pillConstraints(pill, content: contentStack) + [
            playIcon.widthAnchor.constraint(equalToConstant: 24),
            playIcon.heightAnchor.constraint(equalToConstant: 24),

            progressTrack.heightAnchor.constraint(equalToConstant: Self.playProgressTrackHeight),
            progressTrack.widthAnchor.constraint(equalToConstant: Self.playProgressTrackWidth),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth
        ])

        pill.invertOnFocus = [playIcon, titleLabel]
        pill.invertBackgroundOnFocus = [progressTrack]
        pill.invertFillOnFocus = [progressFill]
        return pill
    }

    /// Pill geometry shared with `HeroPillButton`: fixed height, the shared
    /// width as a floor, content centred inside Apple's side padding.
    private static func pillConstraints(_ pill: UIView, content: UIView) -> [NSLayoutConstraint] {
        let restingWidth = pill.widthAnchor.constraint(equalToConstant: actionPillWidth)
        restingWidth.priority = .defaultLow
        return [
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: actionPillWidth),
            restingWidth,
            pill.heightAnchor.constraint(equalToConstant: actionButtonHeight),
            content.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: pill.leadingAnchor, constant: HeroPillButton.sidePadding),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: pill.trailingAnchor, constant: -HeroPillButton.sidePadding)
        ]
    }

    /// Point the Play pill at what pressing it would actually play: `target` is
    /// the hero item for a movie/episode, and the resolved episode for a show.
    /// The bar shows only while the title says Resume, so the two never disagree.
    private func setPlayTarget(_ target: MediaItem) {
        // A multi-cut movie's time left is measured against the selected file.
        let target = target.kind == .movie ? target.withRuntime(copySelection.selectedCutRuntime) : target
        let resumes = target.isInProgress
        playProgressTrack?.isHidden = !resumes
        playProgressFillWidth?.constant = resumes
            ? Self.playProgressTrackWidth * CGFloat(target.watchProgress ?? 0) : 0
        playTitleLabel?.text = EpisodePicker.playTitle(for: target)
    }

    private func makeCircleButton(systemImage: String, caption: String) -> FocusableActionButton {
        let circle = FocusableActionButton()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.focusCaption = caption
        circle.layer.cornerRadius = Self.actionButtonHeight / 2

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        circle.addSubview(icon)

        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: Self.actionButtonHeight),
            circle.heightAnchor.constraint(equalToConstant: Self.actionButtonHeight),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30)
        ])

        circle.invertOnFocus = [icon]
        return circle
    }

    // MARK: - Statics

    private static func formattedAirDate(_ raw: String) -> String? {
        guard let date = plexDateParser.date(from: String(raw.prefix(10))) else { return nil }
        return airDateDisplay.string(from: date)
    }
    private static let plexDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func formatRuntime(_ runtime: TimeInterval) -> String {
        let minutes = Int(runtime / 60)
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours > 0 {
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .show, .season, .episode: return "TV Show"
        case .collection: return "Collection"
        case .person: return "Person"
        case .unknown: return ""
        }
    }

    private static func makeCaptionLabel(_ text: String, alpha: CGFloat) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = captionFont
        l.textColor = UIColor.white.withAlphaComponent(alpha)
        return l
    }

    /// Bordered rating / quality badge, 22pt tall in total (Apple's badge cap).
    private static func makeBadge(_ text: String, alpha: CGFloat) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(alpha)
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(alpha * 0.7).cgColor
        container.layer.cornerRadius = 4
        container.layer.cornerCurve = .continuous
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}

/// What the show page's Watched prompt says: the watched count, and only the
/// choices that would change an episode. Without counts it offers both.
struct ShowWatchPrompt: Equatable {
    struct Choice: Equatable {
        let title: String
        let markWatched: Bool
    }

    static let markWatched = Choice(title: "Mark All Watched", markWatched: true)
    static let markUnwatched = Choice(title: "Mark All Unwatched", markWatched: false)

    let message: String?
    let choices: [Choice]

    init(progress: ChildProgress?) {
        guard let progress, progress.total > 0 else {
            message = nil
            choices = [Self.markWatched, Self.markUnwatched]
            return
        }
        let total = progress.total
        let played = min(max(progress.played, 0), total)
        message = "\(played) of \(total) episodes watched."
        choices = (played < total ? [Self.markWatched] : []) + (played > 0 ? [Self.markUnwatched] : [])
    }
}

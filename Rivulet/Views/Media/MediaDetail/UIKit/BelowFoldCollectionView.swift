// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldCollectionView.swift
//  Rivulet
//
//  The focus-driven below-fold for the expanded detail: a compositional
//  UICollectionView (vertical sections, each an orthogonal horizontal row).
//  Sections this pass: Episodes, Related, Cast & Crew (season pills are a
//  follow-up). Fed by BelowFoldContentLoader. The outer vertical
//  scrollViewDidScroll drives the hero choreography via `onScroll`
//  (contentOffset.y + adjustedContentInset.top). See
//  perf-spike/EXPANDED_DETAIL_CONVERSION_SPIKE.md §1.
//
//  Coexistence: this lives inside ExpandedDetailContainerView, hidden in
//  carousel-stable, and is cross-faded in AFTER the expand morph completes
//  (never on the morph clock — §6). At rest its episodes row peeks at the
//  bottom (large top content inset), matching the placeholder peek position.
//

import UIKit
import os.log

private let copyRailLog = Logger(subsystem: "com.rivulet.app", category: "WaysToWatch")

// nonisolated + Sendable: required to be diffable identifiers under the
// project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (matches HomeSectionID).
nonisolated enum BelowFoldSectionKind: Hashable, Sendable {
    case episodes
    case trailers
    case extras
    case collection
    case related
    case cast
    case whereToWatch
    case servers
    case moreLikeThis
    case about
    case info
}

nonisolated enum BelowFoldItem: Hashable, Sendable {
    case episode(String)
    /// Boundary marker between seasons in the flat rail, keyed by the season
    /// ref itemID it introduces. Structural only — never a focus stop.
    case seasonDivider(String)
    case trailer(String)
    case extra(String)
    /// The whole Related row as ONE item — a ShelfRowCell hosting its own
    /// horizontal collection view, so the row matches the home/library
    /// shelves exactly (geometry, peeks, pitch-aligned landings, glide).
    case relatedShelf
    /// The collection row, hosted exactly like `.relatedShelf`.
    case collectionShelf
    case cast(String)
    /// TMDB watch/providers block (metadata-only items only).
    case whereToWatch
    /// Cross-server availability block (every Plex and unowned title).
    case servers
    /// TMDB recommendations, hosted exactly like `.relatedShelf` (metadata-only
    /// items only — distinct from Plex's `.relatedShelf`).
    case moreLikeThisShelf
    case about       // single full-width card block
    case info        // single full-width columns block
}

final class BelowFoldCollectionView: UIView, UICollectionViewDelegate {

    /// How much of the episode thumbnails peeks at rest (matches the placeholder peek).
    private static let episodePeek: CGFloat = 40
    /// Where every row's content rests in the untransformed collection: under
    /// the collapsed card's metadata. The host pulls the collection left on
    /// expand, which lands it on the expanded margin. Sections measure from
    /// the collection's edges, not its safe area, which changes with the state.
    static let rowLeading: CGFloat = PreviewCarouselGeometry.collapsedChromeInset
    /// The collection is wider than the screen by that pull, so this ends a
    /// row's content on the expanded margin; rails still scroll past it.
    private static let rowTrailing: CGFloat = PreviewCarouselGeometry.expandedChromeInset
    private static let episodeWidth: CGFloat = EpisodeCell.cardWidth
    /// Spacing between episode cards (and season dividers).
    static let episodeGap: CGFloat = MediaRowMetrics.tileGap
    private static let episodeHeight: CGFloat = 435
    private static let trailerWidth: CGFloat = EpisodeCell.cardWidth
    // Same episode card, minus the episode-number / summary / footer rows — so the
    // card hugs thumbnail (245) + 8 + title block (~64).
    private static let trailerHeight: CGFloat = 318
    private static let castWidth: CGFloat = CastCell.circleSize   // cell == circle; labels overflow into the gap

    /// contentOffset.y + adjustedContentInset.top (0 at rest, grows as scrolled).
    var onScroll: ((CGFloat) -> Void)?
    /// Fires when focus lands on an episode cell (the episode), or nil for any
    /// other cell / focus leaving. Drives season-pill tracking in the container.
    var onEpisodeFocused: ((MediaItem?) -> Void)?
    /// Episode thumb Select → play the episode.
    var onPlayEpisode: ((MediaItem) -> Void)?
    /// Trailer / extra Select → play that video (by Plex ratingKey).
    var onPlayTrailer: ((BelowFoldTrailer) -> Void)?
    /// Related or collection-row poster Select (the trailing collection tile
    /// included) → open that item's detail page (blur-fade).
    var onShowRelatedDetails: ((MediaItem) -> Void)?
    /// Episode description Select → open the episode detail page.
    var onShowEpisodeDetails: ((MediaItem) -> Void)?
    /// On Your Servers card Select → switch the page to that copy (`DetailCopy.id`).
    var onSelectServerCopy: ((String) -> Void)?
    /// Cast / crew cell Select → open the person detail page.
    var onSelectPerson: ((MediaPerson) -> Void)?
    /// Selecting the About cards opens the matching popup (synopsis / advisory).
    var onSelectSynopsis: ((MediaItemDetail) -> Void)?
    var onSelectAdvisory: ((ContentAdvisory) -> Void)?
    /// The loader's seasons, published as soon as they land, with the index of
    /// the season it resolved as selected. The container builds the season pills
    /// from this instead of fetching `/children` a second time of its own.
    var onSeasonsLoaded: (([MediaItem], Int) -> Void)?

    /// Which sub-target of the focused episode card is focused (thumb vs
    /// description). Set from the cell's focus reporting.
    private(set) var focusedEpisodeKind: EpisodeFocusKind = .none
    /// When the episode thumb most recently took focus. Up that lands on the
    /// thumb within the same-press window (coming up from the description or a
    /// lower row) must STICK on the thumb; only a deliberate Up from a resting
    /// thumb lifts to the season pills.
    private var lastThumbFocusTime: CFTimeInterval = 0

    private var collectionView: FocusScrollControlledCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>!
    private var sectionKinds: [BelowFoldSectionKind] = []

    private let loader = BelowFoldContentLoader()
    private var loadToken: UInt64 = 0
    /// Last item handed to `configure`/`configureEpisodesOnly`. Held so a
    /// watch-state refresh can re-run the episode fetch without the host
    /// having to re-plumb the item (issue #228).
    private var configuredItem: MediaItem?
    /// True while `configureEpisodesOnly` is fetching; `onEpisodesApplied`
    /// fires once when its snapshot is in, so the host's fade waits for content.
    private(set) var isLoadingEpisodes = false
    var onEpisodesApplied: (() -> Void)?

    private var episodesByID: [String: MediaItem] = [:]
    /// The show page's selected copy (`setEpisodeCopy`), nil for its own.
    private var episodeCopy: EpisodeCopy?
    /// Episodes of the page's own copy that the selected copy lacks: listed
    /// greyed, playing nothing.
    private var unavailableEpisodeIDs: Set<String> = []
    private var copyToken: UInt64 = 0
    /// True once the full below-fold (seasons included) has been ingested.
    private var hasFullContent = false
    private var trailersByID: [String: BelowFoldTrailer] = [:]
    private var extrasByID: [String: BelowFoldTrailer] = [:]
    private var castEntriesByID: [String: CastEntry] = [:]
    private var multiSeason = false
    /// Full detail for the About + Information/Languages/Accessibility blocks.
    private var detail: MediaItemDetail?
    /// SHOW detail for episode/season opens (the About card describes the show);
    /// nil for movies/show-level (use `detail`).
    private var showDetail: MediaItemDetail?

    private struct CastEntry { let person: MediaPerson; let subtitle: String? }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        collectionView = FocusScrollControlledCollectionView(frame: bounds, collectionViewLayout: makeLayout())
        collectionView.topBand = Self.detailsTopY
        // Disable the collection's own (vertical) scrolling so the focus engine
        // can't spin up its centering "focus scroll animator". We drive all
        // vertical scroll ourselves (slide on entry, didUpdateFocus per section).
        // Orthogonal (horizontal) row scrolling is a separate inner scroller.
        collectionView.isScrollEnabled = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        // OFF: "remember last focused" would win over indexPathForPreferredFocusedView
        // and the geometric Down entry, so Down from a season pill snapped focus
        // back to the remembered episode (season 1 ep0). Without it, Down enters
        // the current season's first episode (nearest-visible / preferred index).
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(EpisodeCollectionCell.self, forCellWithReuseIdentifier: EpisodeCollectionCell.reuseID)
        collectionView.register(SeasonDividerCell.self, forCellWithReuseIdentifier: SeasonDividerCell.reuseID)
        collectionView.register(TrailerCollectionCell.self, forCellWithReuseIdentifier: TrailerCollectionCell.reuseID)
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        collectionView.register(CastCollectionCell.self, forCellWithReuseIdentifier: CastCollectionCell.reuseID)
        collectionView.register(AboutCollectionCell.self, forCellWithReuseIdentifier: AboutCollectionCell.reuseID)
        collectionView.register(InfoColumnsCollectionCell.self, forCellWithReuseIdentifier: InfoColumnsCollectionCell.reuseID)
        collectionView.register(WhereToWatchCollectionCell.self, forCellWithReuseIdentifier: WhereToWatchCollectionCell.reuseID)
        collectionView.register(ServerAvailabilityCollectionCell.self, forCellWithReuseIdentifier: ServerAvailabilityCollectionCell.reuseID)
        collectionView.register(
            BelowFoldSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BelowFoldSectionHeader.reuseID
        )
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configureDataSource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BelowFoldCollectionView is not Storyboard-backed") }

    /// Forward focus into the collection (the engine finds the first focusable cell).
    ///
    /// EXCEPT when restoring into a shelf-host row (Related) after a modal: that
    /// row is one cell wrapping its own collection, so it cannot be expressed
    /// through `indexPathForPreferredFocusedView` — returning the host path
    /// makes the nested collection restart at item 0. Prefer the host CELL
    /// directly instead, and its own `preferredFocusEnvironments` (armed by
    /// `restoreShelfRowFocusIfNeeded`) lands the tile that had focus.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let shelf = armedShelfRestoreCell { return [shelf] }
        return [collectionView]
    }

    /// Shelf-host cell armed for focus restore, consumed by the next focus update.
    private weak var armedShelfRestoreCell: ShelfRowCell?

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Small top inset = where episodes land in details (so the focus engine
        // aligns them there). The carousel-stable peek offset is provided by the
        // large TOP INSET on the episodes section (see makeLayout), not by this.
        let topInset = Self.detailsTopY
        if collectionView.contentInset.top != topInset {
            collectionView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            collectionView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
        }
        // Position the rail at the carousel item's season BEFORE first render
        // (no visible scroll). Retry until the orthogonal scroller is built.
        if let target = pendingInitialScroll {
            collectionView.layoutIfNeeded()   // ensure the orthogonal scroller exists
            if scrollOrthogonalEpisodes(toItem: target.item, epSection: target.section, animated: false) {
                pendingInitialScroll = nil
            }
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, env in
            guard let self, self.sectionKinds.indices.contains(index) else { return nil }
            // The FIRST section is the "primary peek row" — Episodes for shows,
            // Related for movies. A large TOP inset on it provides the carousel-
            // stable peek (it peeks at the bottom) AND the scroll distance that
            // drives the Down slide + backdrop blur + chrome fade. Without this on
            // the first section, movies (Trailers first) had a tiny inset, so the
            // slide barely moved and the blur/fade never triggered.
            let isPrimary = (index == 0)
            let peek = max(0, self.bounds.height - Self.episodePeek - Self.detailsTopY)
            switch self.sectionKinds[index] {
            // Episodes: LEFT-aligned (ATV+), first card at the metadata inset.
            // The collection's small contentInset.top (= detailsTopY)
            // lets the focus engine land them at ~detailsTopY in details.
            case .episodes:
                return self.episodesRailSection(
                    topInset: isPrimary ? peek : 0,
                    sectionBottomInset: 36
                )
            case .trailers:
                return self.shelfSection(
                    itemW: Self.trailerWidth,
                    itemH: Self.trailerHeight,
                    gap: MediaRowMetrics.tileGap,
                    header: !isPrimary,
                    topInset: isPrimary ? peek : 0,
                    headerTopInset: 8,
                    headerHeight: 44,
                    sectionBottomInset: 96
                )
            case .extras:
                return self.shelfSection(
                    itemW: Self.trailerWidth,
                    itemH: Self.trailerHeight,
                    gap: MediaRowMetrics.tileGap,
                    header: !isPrimary,
                    topInset: isPrimary ? peek : 0,
                    headerTopInset: 8,
                    headerHeight: 44,
                    sectionBottomInset: 96
                )
            case .related, .collection:
                // The collection row shares this: on a movie with no trailers
                // or extras it is the primary peek row, so it needs the same lift.
                // Home-identical shelf: one full-width ShelfRowCell hosting
                // the posters (margin, peek, pitch landings).
                // As the primary row, lift the section by its own header (+ the
                // section's 8pt pad) so the 40pt peek strip is POSTER, like the
                // episodes row — the "Related" title rides just above it.
                let relatedLift = ShelfRowCell.headerHeight + 8
                return self.homeShelfHostSection(
                    topInset: isPrimary ? max(0, peek - relatedLift) : 0,
                    sectionBottomInset: isPrimary ? 36 : 56
                )
            case .cast:
                return self.shelfSection(
                    itemW: Self.castWidth,
                    itemH: CastCell.height,
                    gap: MediaRowMetrics.tileGap,   // six across on the grid, the seventh peeking
                    header: true,
                    // Primary on a title with no extras or related: same peek,
                    // less the header gap, so the strip is the cast row.
                    topInset: isPrimary ? max(0, peek - 16) : 0
                )
            case .moreLikeThis:
                // Hosted exactly like `.related`/`.collection` — same lift math.
                let lift = ShelfRowCell.headerHeight + 8
                return self.homeShelfHostSection(
                    topInset: isPrimary ? max(0, peek - lift) : 0,
                    sectionBottomInset: isPrimary ? 36 : 56
                )
            case .whereToWatch:
                let height = WhereToWatchCollectionCell.height(for: self.watchAvailability ?? .empty)
                return self.fullWidthSection(height: height, topInset: isPrimary ? peek : 0)
            case .servers:
                return self.fullWidthSection(height: ServerAvailabilityCollectionCell.height,
                                             topInset: isPrimary ? peek : 0)
            case .about: return self.fullWidthSection(height: 370, topInset: isPrimary ? peek : 0)
            case .info:
                // Sized to its rows, so a short title leaves no empty band below them.
                let columnsWidth = env.container.contentSize.width - Self.rowLeading - Self.rowTrailing
                let height = self.detail.map { InfoColumnsCollectionCell.height(for: $0, columnsWidth: columnsWidth) }
                return self.fullWidthSection(height: height ?? 605, band: true)
            }
        }
        return layout
    }

    /// One full-width item hosting a ShelfRowCell (the Related row). NOT an
    /// orthogonal section — the shelf cell drives its own horizontal scroll
    /// with the home shelf's exact geometry and landings. The item spans the
    /// whole (panel + overshoot) collection width; panel alignment happens
    /// inside the cell via panelOvershoot.
    private func homeShelfHostSection(topInset: CGFloat = 0,
                                      sectionBottomInset: CGFloat = 56) -> NSCollectionLayoutSection {
        // The ShelfRowCell draws its own header (self-aligned with the tiles),
        // so there's NO supplementary header — just one full-width item tall
        // enough for the header + the row.
        let rowHeight = ShelfRowCell.headerHeight + MediaRowMetrics.posterHeight
            + MediaRowMetrics.posterCaptionHeight + MediaRowMetrics.focusGrowthPadding
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(rowHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = .init(
            top: 8 + topInset,
            leading: 0,
            bottom: sectionBottomInset,
            trailing: 0
        )
        return section
    }

    /// A single full-width block (About / Info columns) — no orthogonal scroll,
    /// left/right gutters matching the rails.
    private func fullWidthSection(height: CGFloat, band: Bool = false,
                                  topInset: CGFloat = 0) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = .init(top: 24 + topInset, leading: Self.rowLeading, bottom: 56,
                                      trailing: Self.rowTrailing)
        if band {
            // The cell paints the band itself, so it spans the whole collection
            // width and insets its own content.
            section.contentInsets = .zero
        }
        return section
    }

    /// The episode rail's section. A custom group instead of `shelfSection`'s
    /// repeating item because the rail mixes widths: full episode cards plus
    /// slim season dividers. Frames are computed eagerly from `cachedEpisodes`
    /// (the provider closure re-runs on every data-driven invalidation), so
    /// layout attributes — and everything that reads them: the orthogonal
    /// season scroll, pill alignment, initial-episode landing — stay exact,
    /// which estimated self-sizing would not guarantee.
    private func episodesRailSection(topInset: CGFloat, sectionBottomInset: CGFloat) -> NSCollectionLayoutSection {
        let gap = Self.episodeGap
        var frames: [CGRect] = []
        var x: CGFloat = 0
        for railItem in cachedEpisodes {
            let w: CGFloat
            if case .seasonDivider = railItem { w = SeasonDividerCell.cardWidth } else { w = Self.episodeWidth }
            frames.append(CGRect(x: x, y: 0, width: w, height: Self.episodeHeight))
            x += w + gap
        }
        let total = max(x - gap, 1)
        let group = NSCollectionLayoutGroup.custom(layoutSize: .init(
            widthDimension: .absolute(total), heightDimension: .absolute(Self.episodeHeight))
        ) { _ in
            frames.map { NSCollectionLayoutGroupCustomItem(frame: $0) }
        }
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsetsReference = .none
        section.contentInsets = .init(
            top: topInset,
            leading: Self.rowLeading,
            bottom: sectionBottomInset,
            trailing: Self.rowTrailing
        )
        return section
    }

    private func shelfSection(
        itemW: CGFloat,
        itemH: CGFloat,
        gap: CGFloat,
        header: Bool,
        topInset: CGFloat = 0,
        headerTopInset: CGFloat = 16,
        headerHeight: CGFloat = 44,
        sectionBottomInset: CGFloat = 56
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(itemW), heightDimension: .absolute(itemH)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(itemW), heightDimension: .absolute(itemH)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = gap
        section.contentInsetsReference = .none
        section.contentInsets = .init(
            top: (header ? headerTopInset : 0) + topInset,
            leading: Self.rowLeading,
            bottom: sectionBottomInset,
            trailing: Self.rowTrailing
        )
        if header {
            let headerItem = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(headerHeight)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top,
                // The section's top inset does not move its header. Offset, the
                // header sits above that point and reserves no height of its own.
                absoluteOffset: CGPoint(x: 0, y: topInset))
            // Do not apply the row leading again here. The section already owns
            // the leading inset; adding it to the boundary header double-indents
            // titles away from their cards.
            headerItem.contentInsets = .zero
            section.boundarySupplementaryItems = [headerItem]
        }
        return section
    }

    // MARK: - Data source

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>(
            collectionView: collectionView
        ) { [weak self] cv, indexPath, item in
            guard let self else { return UICollectionViewCell() }
            switch item {
            case .episode(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
                if let ep = self.episodesByID[id] {
                    let unavailableOn = self.unavailableEpisodeIDs.contains(id) ? self.episodeCopy?.serverName : nil
                    cell.configure(episode: ep, showSeasonPrefix: self.multiSeason, unavailableOn: unavailableOn)
                    // Per-cell focus drives season-pill tracking (fires on every
                    // horizontal move; the collection's didUpdateFocus does not).
                    cell.onFocused = { [weak self] focused in
                        if focused { self?.pendingInitialFocus = nil; self?.onEpisodeFocused?(ep) }
                    }
                    // Two focus stops: thumb = play, description = detail page.
                    cell.onPlay = unavailableOn == nil ? { [weak self] in self?.onPlayEpisode?(ep) } : nil
                    cell.onShowDetails = { [weak self] in self?.onShowEpisodeDetails?(ep) }
                    cell.onFocusKind = { [weak self] kind in
                        guard let self else { return }
                        if kind == .thumb { self.lastThumbFocusTime = CACurrentMediaTime() }
                        self.focusedEpisodeKind = kind
                    }
                }
                return cell
            case .seasonDivider(let seasonID):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: SeasonDividerCell.reuseID, for: indexPath) as! SeasonDividerCell
                cell.configure(label: self.railDividerLabels[seasonID] ?? "·")
                return cell
            case .trailer(let id):
                // Trailers reuse the EpisodeCollectionCell so they match episodes
                // exactly (TVCardView thumbnail + sheen + frosted focus panel).
                let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
                cell.onFocused = nil   // trailers don't drive season-pill tracking
                if let trailer = self.trailersByID[id] {
                    cell.configure(trailer: trailer)
                    cell.onPlay = { [weak self] in self?.onPlayTrailer?(trailer) }
                }
                return cell
            case .extra(let id):
                // Extras render exactly like trailers (same cell + playback path).
                let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
                cell.onFocused = nil
                if let extra = self.extrasByID[id] {
                    cell.configure(trailer: extra)
                    cell.onPlay = { [weak self] in self?.onPlayTrailer?(extra) }
                }
                return cell
            case .collectionShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                let row = self.collectionRow
                self.configurePosterShelf(cell, section: .collection, title: row?.title ?? "",
                                          items: row?.members ?? [], trailing: row?.collection)
                return cell
            case .relatedShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                self.configurePosterShelf(cell, section: .related, title: "Related",
                                          items: self.relatedItems, trailing: nil)
                return cell
            case .cast(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: CastCollectionCell.reuseID, for: indexPath) as! CastCollectionCell
                if let e = self.castEntriesByID[id] { cell.configure(person: e.person, fallbackSubtitle: e.subtitle) }
                return cell
            case .whereToWatch:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: WhereToWatchCollectionCell.reuseID, for: indexPath) as! WhereToWatchCollectionCell
                cell.configure(availability: self.watchAvailability ?? .empty)
                return cell
            case .servers:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ServerAvailabilityCollectionCell.reuseID, for: indexPath) as! ServerAvailabilityCollectionCell
                cell.configure(availability: self.serverAvailability ?? .checking)
                cell.onSelectCopy = { [weak self] entry in self?.onSelectServerCopy?(entry.copyID) }
                return cell
            case .moreLikeThisShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                self.configurePosterShelf(cell, section: .moreLikeThis, title: "More Like This",
                                          items: self.moreLikeThisItems, trailing: nil)
                return cell
            case .about:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: AboutCollectionCell.reuseID, for: indexPath) as! AboutCollectionCell
                cell.onSelectSynopsis = { [weak self] d in self?.onSelectSynopsis?(d) }
                cell.onSelectAdvisory = { [weak self] a in self?.onSelectAdvisory?(a) }
                // About always describes the SHOW (show detail for episodes/seasons).
                if let d = self.showDetail ?? self.detail { cell.configure(detail: d) }
                return cell
            case .info:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: InfoColumnsCollectionCell.reuseID, for: indexPath) as! InfoColumnsCollectionCell
                if let d = self.detail { cell.configure(detail: d) }
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
            guard let self, kind == UICollectionView.elementKindSectionHeader,
                  self.sectionKinds.indices.contains(indexPath.section) else { return nil }
            let header = cv.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: BelowFoldSectionHeader.reuseID, for: indexPath) as! BelowFoldSectionHeader
            switch self.sectionKinds[indexPath.section] {
            case .trailers: header.configure(title: "Trailers")
            case .extras:  header.configure(title: "Extras")
            case .related: header.configure(title: "Related")
            case .cast:    header.configure(title: "Cast & Crew")
            case .episodes, .collection, .about, .info,
                 .whereToWatch, .servers, .moreLikeThis: header.configure(title: "")
            }
            return header
        }
    }

    /// One body for both poster shelves (Collection, Related) so they cannot
    /// drift. Every tile, the trailing collection tile included, opens through
    /// `onShowRelatedDetails`; `presentStandaloneDetail` routes a collection
    /// to its page. The content token hashes each tile's ratingKey and watch
    /// state, so a watch-state refresh reloads the row (under the shelf's
    /// cross-dissolve) only when a glyph moved. The row keeps its horizontal
    /// offset across that reload and across host-cell reuse.
    private func configurePosterShelf(_ cell: ShelfRowCell,
                                      section: BelowFoldSectionKind,
                                      title: String,
                                      items: [MediaItem],
                                      trailing: MediaItem?) {
        let tiles = items + (trailing.map { [$0] } ?? [])
        var hasher = Hasher()
        for tile in tiles {
            hasher.combine(tile.ref.itemID)
            hasher.combine(tile.userState.isPlayed)
            hasher.combine(tile.userState.viewOffset)
        }
        cell.cellProvider = { innerCV, ip in
            let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: ip) as! PosterCell
            if ip.item < tiles.count { poster.configure(item: tiles[ip.item]) }
            return poster
        }
        cell.onSelect = { [weak self] idx in
            guard let self, idx < tiles.count else { return }
            self.onShowRelatedDetails?(tiles[idx])
        }
        cell.onWillDisplayItem = nil
        cell.onLongPressItem = nil
        cell.onOffsetChanged = { [weak self] offset in self?.shelfOffsets[section] = offset }
        // Rests under the collapsed metadata; the expand pull lands it on the margin.
        cell.headerTitle = title
        cell.configure(
            kind: .poster,
            realCount: tiles.count,
            hasSkeleton: false,
            contentToken: hasher.finalize(),
            initialOffset: shelfOffsets[section] ?? 0,
            panelOvershoot: (left: Self.rowLeading - MediaRowMetrics.rowLeading, right: 0)
        )
    }

    // MARK: - Configure (fetch + populate)

    /// Load + render the below-fold for `item`. `detail` (if the chrome already
    /// fetched it) supplies cast without a second round-trip.
    func configure(item: MediaItem, detail: MediaItemDetail?) {
        loadToken &+= 1
        let token = loadToken
        configuredItem = item
        isLoadingEpisodes = false
        Task { [weak self] in
            guard let self else { return }
            var content = await self.loader.load(for: item, detail: detail)
            var missing: Set<String> = []
            if let copy = self.activeCopy(for: item),
               let merged = await Self.merged(with: copy, original: content.episodes, originalSeasons: content.seasons) {
                content.seasons = merged.seasons
                content.selectedSeason = merged.seasons.first
                content.episodes = merged.episodes
                missing = merged.missing
            }
            guard self.loadToken == token else { return }
            self.unavailableEpisodeIDs = missing
            self.ingest(content)
            self.applySnapshot()
            self.scrollToInitialEpisode(item: item)
            // Cross-server check: its own task, patching the Servers cell in
            // place when it answers, so neither the render above nor the
            // advisory below waits on it. An owned title is found by the Plex
            // guid in its detail, an unowned one by its TMDB id.
            if content.serverAvailability != nil {
                let detail = content.detail
                Task { [weak self] in
                    guard let self else { return }
                    let availability = await self.loader.loadServerAvailability(for: item, detail: detail)
                    guard self.loadToken == token else { return }
                    self.applyServerAvailability(availability ?? .notFound)
                }
            }
            // CHAINED (not a racing Task): the full content advisory is fetched
            // AFTER ingest, so it can't be clobbered by `ingest` overwriting
            // `self.detail` with the partial. Render already happened at
            // applySnapshot, so this is still non-blocking. Patch the About cell.
            let advisory = await self.loader.loadAdvisory(for: item)
            guard self.loadToken == token, let advisory else { return }
            self.applyContentAdvisory(advisory)
        }
        // Cross-server check: slow on its first call this session (pages
        // every other server's library once), so it runs as its own chained
        // fetch and patches the Servers cell in place — never blocking the
        // initial render above. Gated on `isMetadataOnly` directly (not on
        // `self.serverAvailability`, which this races against `ingest` to set).

    }

    /// Patch the Servers cell with the real cross-server answer once it
    /// resolves, without a full snapshot rebuild (focus-preserving) — mirrors
    /// `applyContentAdvisory` above.
    private func applyServerAvailability(_ availability: ServerAvailability) {
        serverAvailability = availability
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.servers) else { return }
        snapshot.reconfigureItems([.servers])
        dataSource.apply(snapshot, animatingDifferences: false)
        updateStaticSections()
    }

    /// Sections with nothing to focus: Where to Watch always, On Your
    /// Servers until it has a copy to play. The collection keeps them in
    /// view while focus passes them (`staticSections`), so stepping from
    /// Cast & Crew to the next row shows the logos instead of skipping them.
    private func updateStaticSections() {
        var statics = Set<Int>()
        for (index, kind) in sectionKinds.enumerated() {
            switch kind {
            case .whereToWatch: statics.insert(index)
            case .servers:
                if case .found(let entries) = serverAvailability, !entries.isEmpty { continue }
                statics.insert(index)
            default: continue
            }
        }
        collectionView.staticSections = statics
    }



    /// Patch the About cell with the rich advisory after it arrives, without a
    /// full snapshot rebuild (focus-preserving). No-op if About isn't present.
    private func applyContentAdvisory(_ advisory: ContentAdvisory) {
        guard detail != nil else { return }
        // Set on whichever detail the About card renders (show detail for
        // episodes/seasons, else the item detail).
        if showDetail != nil { showDetail?.contentAdvisory = advisory }
        else { detail?.contentAdvisory = advisory }
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.about) else { return }
        snapshot.reconfigureItems([.about])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selected copy

    /// Another server's or library's copy of the show a page switched to.
    struct EpisodeCopy: Equatable {
        /// The page's own show, which this copy stands in for.
        let original: MediaItemRef
        /// The copy's show, on its own server (`plex:<machineId>`).
        let show: MediaItem
        let machineId: String
        let serverName: String
        let serverURL: String
        let token: String
    }

    /// List `copy`'s episodes (nil: the page's own). A show page only, and
    /// only for the show it stands in for; reloads the rail when that show is up.
    func setEpisodeCopy(_ copy: EpisodeCopy?) {
        guard copy != episodeCopy else { return }
        episodeCopy = copy
        guard let item = configuredItem, item.kind == .show else { return }
        reloadEpisodes(for: item)
    }

    /// The copy the rail lists now, nil for the item's own.
    var currentEpisodeCopy: EpisodeCopy? { configuredItem.flatMap(activeCopy(for:)) }

    private func activeCopy(for item: MediaItem) -> EpisodeCopy? {
        guard item.kind == .show, let copy = episodeCopy, copy.original == item.ref else { return nil }
        return copy
    }

    /// The copy's server, registered on first use so its episodes open, play
    /// and report on that server (`PlexItemServer`).
    static func provider(for copy: EpisodeCopy) -> (any MediaProvider)? {
        let registry = MediaProviderRegistry.shared
        if let provider = registry.provider(for: copy.show.ref.providerID) { return provider }
        registry.registerAdditionalPlex(PlexProvider(machineIdentifier: copy.machineId, displayName: copy.serverName,
                                                     serverURL: copy.serverURL, authToken: copy.token))
        return registry.provider(for: copy.show.ref.providerID)
    }

    /// The copy's seasons and episodes with the original's it lacks; nil
    /// when the copy's server did not answer, which keeps the original list.
    private static func merged(with copy: EpisodeCopy, original: [MediaItem],
                               originalSeasons: [MediaItem]) async -> CopyEpisodes.Merged? {
        guard let provider = provider(for: copy) else { return nil }
        async let seasons = try? provider.children(of: copy.show.ref)
        async let episodes = try? provider.allEpisodes(of: copy.show.ref)
        guard let copyEpisodes = await episodes else {
            copyRailLog.error("[Copies] rail: \(copy.serverName, privacy: .public) did not answer; listing the page's own copy")
            return nil
        }
        let merged = CopyEpisodes.merge(copy: copyEpisodes, copySeasons: await seasons ?? [],
                                        original: original, originalSeasons: originalSeasons)
        copyRailLog.info("[Copies] rail: \(copy.show.title, privacy: .public) from \(copy.serverName, privacy: .public) (\(copy.show.ref.itemID, privacy: .public)): \(copyEpisodes.count, privacy: .public) episodes, \(merged.missing.count, privacy: .public) not there")
        return merged
    }

    /// The rail (and, once expanded, the season pills) again for the current
    /// copy, leaving the rest of the below-fold as it is.
    private func reloadEpisodes(for item: MediaItem) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        copyToken &+= 1
        let token = copyToken
        let load = loadToken
        let full = hasFullContent
        let copy = activeCopy(for: item)
        Task { [weak self] in
            guard let self else { return }
            var episodes = (try? await provider.allEpisodes(of: item.ref)) ?? []
            var seasons = full ? (try? await provider.children(of: item.ref)) ?? [] : []
            var missing: Set<String> = []
            if let copy, let merged = await Self.merged(with: copy, original: episodes, originalSeasons: seasons) {
                episodes = merged.episodes
                seasons = merged.seasons
                missing = merged.missing
            }
            guard self.copyToken == token, self.loadToken == load, !episodes.isEmpty else { return }
            self.unavailableEpisodeIDs = missing
            self.multiSeason = full ? seasons.count > 1 : Set(episodes.compactMap(\.seasonNumber)).count > 1
            self.episodesByID = Dictionary(episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
            self.cachedEpisodes = self.buildRailItems(from: episodes)
            self.applySnapshot()
            if full { self.onSeasonsLoaded?(seasons, 0) }
        }
    }

    /// Episodes-only load for the carousel-stable peek (per page) — skips the
    /// heavier cast/related fetch until expand.
    func configureEpisodesOnly(item: MediaItem) {
        loadToken &+= 1
        let token = loadToken
        // A different item: empty the rail now, so the previous show's
        // episodes never sit under this card while the fetch runs.
        let itemChanged = configuredItem?.ref != item.ref
        configuredItem = item
        isLoadingEpisodes = false
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            ingestEpisodesOnly([]); applySnapshot(); return
        }
        if itemChanged { ingestEpisodesOnly([]); applySnapshot() }
        // A movie fetches nothing here, so its fade does not wait.
        isLoadingEpisodes = showRef != nil || item.kind == .season
        Task { [weak self] in
            guard let self else { return }
            let eps: [MediaItem]
            if let showRef {
                eps = (try? await provider.allEpisodes(of: showRef)) ?? []
            } else if item.kind == .season {
                eps = (try? await provider.children(of: item.ref)) ?? []
            } else {
                eps = []
            }
            var listed = eps
            var missing: Set<String> = []
            if let copy = self.activeCopy(for: item),
               let merged = await Self.merged(with: copy, original: eps, originalSeasons: []) {
                listed = merged.episodes
                missing = merged.missing
            }
            guard self.loadToken == token else { return }
            self.unavailableEpisodeIDs = missing
            self.ingestEpisodesOnly(listed)
            self.applySnapshot()
            self.scrollToInitialEpisode(item: item)
            self.isLoadingEpisodes = false
            // Realize the cells now, so the fade starts over a built rail.
            self.collectionView.layoutIfNeeded()
            let applied = self.onEpisodesApplied
            self.onEpisodesApplied = nil
            applied?()
        }
    }

    /// Re-read the episode rail's watch state from the server and repaint the
    /// cards in place (issue #228: the rail kept rendering the pre-playback
    /// snapshot after the player dismissed).
    ///
    /// Deliberately NOT a re-`configure`: the diffable identifiers are
    /// `.episode(ratingKey)`, so a plain re-apply is an empty diff and the
    /// cells never redraw. Instead the fresh items are swapped into
    /// `episodesByID` and the same identifiers are `reconfigureItems`-ed, which
    /// re-runs `cellForItemAt` on the EXISTING cells — no insert/delete, so the
    /// focus engine keeps whatever is focused. `allEpisodes` is an uncached GET,
    /// so this always reads the committed server state.
    func refreshWatchState() {
        guard let item = configuredItem else { return }
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        // Its OWN token, not `loadToken`: bumping that one would invalidate an
        // in-flight `configure`. Both the refresh token AND the load token are
        // checked on landing, so a refresh is dropped if a newer refresh or ANY
        // configure has started since.
        refreshToken &+= 1
        let refresh = refreshToken
        let load = loadToken
        // Nothing to repaint in the carousel-stable episodes-only phase
        // (`ingestEpisodesOnly` clears both), so skip /related and the
        // collection fetch. Read before the await: the stores can change under it.
        let hasShelves = collectionRow != nil || !cachedRelated.isEmpty
        let copy = activeCopy(for: item)
        Task { [weak self] in
            guard let self else { return }
            let eps: [MediaItem]
            if let copy, let copyProvider = Self.provider(for: copy) {
                // The selected copy's states; its missing episodes have none to refresh.
                eps = (try? await copyProvider.allEpisodes(of: copy.show.ref)) ?? []
            } else if let showRef {
                eps = (try? await provider.allEpisodes(of: showRef)) ?? []
            } else if item.kind == .season {
                eps = (try? await provider.children(of: item.ref)) ?? []
            } else {
                eps = []
            }
            guard self.refreshToken == refresh, self.loadToken == load else { return }
            if !eps.isEmpty { self.applyRefreshedEpisodes(eps) }
            // Collection and Related tiles carry watch glyphs too. Same call
            // and same kinds as the loader's collection row; it runs after the
            // rail repaint so the rail never waits on a second GET.
            guard hasShelves, item.kind == .movie || item.kind == .show,
                  let fresh = try? await provider.related(for: item.ref, kind: item.kind),
                  self.refreshToken == refresh, self.loadToken == load else { return }
            self.applyRefreshedShelves(fresh)
        }
    }

    private var refreshToken: UInt64 = 0

    /// Swap refreshed Collection members and Related items into their stores
    /// and reconfigure the two shelf host cells in place, which re-runs
    /// `configurePosterShelf` on the EXISTING cells. The collection row keeps
    /// its title and trailing tile from the load: only watch state is news.
    // ponytail: a refresh never adds or removes a row, so a collection or
    // Related row that appears or empties between load and refresh waits for
    // the next open; insert/delete with a focus hand-off if that ever matters.
    private func applyRefreshedShelves(_ fresh: RelatedContent) {
        var snapshot = dataSource.snapshot()
        let present = snapshot.itemIdentifiers
        var targets: [BelowFoldItem] = []
        if present.contains(.collectionShelf), let row = collectionRow,
           let members = fresh.collection?.members, !members.isEmpty {
            collectionRow = CollectionRow(title: row.title, members: members, collection: row.collection)
            targets.append(.collectionShelf)
        }
        if present.contains(.relatedShelf), !fresh.items.isEmpty {
            relatedItems = fresh.items
            targets.append(.relatedShelf)
        }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Swap freshly-fetched episodes into the lookup and reconfigure only the
    /// identifiers whose content actually changed.
    private func applyRefreshedEpisodes(_ episodes: [MediaItem]) {
        var changed: [BelowFoldItem] = []
        for episode in episodes {
            let id = episode.ref.itemID
            guard let existing = episodesByID[id] else { continue }
            guard existing != episode else { continue }
            episodesByID[id] = episode
            changed.append(.episode(id))
        }
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        // Only reconfigure identifiers the snapshot still holds — a refresh can
        // land after the rail has been re-configured for a different show.
        let present = Set(snapshot.itemIdentifiers)
        let targets = changed.filter { present.contains($0) }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func ingestEpisodesOnly(_ episodes: [MediaItem]) {
        hasFullContent = false
        // Match the full-ingest label format: a multi-season show shows "S01E01"
        // prefixes, not "Episode N". (Derived from the episodes themselves since
        // the lighter peek load doesn't fetch the seasons list.)
        multiSeason = Set(episodes.compactMap { $0.seasonNumber }).count > 1
        episodesByID = Dictionary(episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        cachedEpisodes = buildRailItems(from: episodes)
        // Cast/related/about are loaded only on expand.
        trailersByID = [:]; extrasByID = [:]; castEntriesByID = [:]
        cachedTrailers = []; cachedExtras = []; cachedRelated = []; cachedCastOrder = []
        collectionRow = nil; shelfOffsets = [:]
        cachedMoreLikeThis = []; moreLikeThisItems = []
        watchAvailability = nil; serverAvailability = nil
        detail = nil
    }

    private func ingest(_ content: BelowFoldContent) {
        hasFullContent = true
        detail = content.detail
        showDetail = content.showDetail
        multiSeason = content.seasons.count > 1
        episodesByID = Dictionary(content.episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        trailersByID = Dictionary(content.trailers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        extrasByID = Dictionary(content.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var entries: [String: CastEntry] = [:]
        cachedCastOrder = []
        // Dedup by id: two credits can collapse to the same identifier (e.g. the
        // same name in the same role, "cast:Mike Desilets-(voice)-"). Appending
        // both would feed duplicate identifiers into the diffable snapshot and
        // trip NSDiffableDataSourceSnapshot's uniqueness assertion (RIVULET-4R).
        // First occurrence wins, keeping order and entry data consistent.
        var seenCastIDs = Set<String>()
        for d in content.directors {
            let id = "dir:\(d.id)"
            guard seenCastIDs.insert(id).inserted else { continue }
            entries[id] = CastEntry(person: d, subtitle: "Director")
            cachedCastOrder.append((id, .cast(id)))
        }
        for c in content.cast {
            let id = "cast:\(c.id)"
            guard seenCastIDs.insert(id).inserted else { continue }
            entries[id] = CastEntry(person: c, subtitle: c.role)
            cachedCastOrder.append((id, .cast(id)))
        }
        castEntriesByID = entries
        cachedEpisodes = buildRailItems(from: content.episodes)
        cachedTrailers = content.trailers.map { BelowFoldItem.trailer($0.id) }
        cachedExtras = content.extras.map { BelowFoldItem.extra($0.id) }
        relatedItems = content.related
        cachedRelated = content.related.isEmpty ? [] : [BelowFoldItem.relatedShelf]
        collectionRow = content.collection
        moreLikeThisItems = content.moreLikeThis
        cachedMoreLikeThis = content.moreLikeThis.isEmpty ? [] : [BelowFoldItem.moreLikeThisShelf]
        watchAvailability = content.watchAvailability
        serverAvailability = content.serverAvailability
        shelfOffsets = [:]

        // Publish the seasons once everything else is ingested, so a handler that
        // reads back from this view sees a consistent state. The loader has
        // already resolved which season to open on (the item's own for a season
        // page, the parent for an episode, the first for a show), so there is
        // nothing for the container to re-derive — or to re-fetch.
        let selectedSeasonIndex = content.selectedSeason
            .flatMap { sel in content.seasons.firstIndex(where: { $0.ref.itemID == sel.ref.itemID }) } ?? 0
        onSeasonsLoaded?(content.seasons, selectedSeasonIndex)
    }

    /// Build the flat rail: the episodes, with a season divider inserted at each
    /// boundary. A single-season rail gets none — the divider marks a
    /// transition, and with one season there is nothing to transition from.
    private func buildRailItems(from episodes: [MediaItem]) -> [BelowFoldItem] {
        let seasonIDs = Set(episodes.compactMap { $0.parentRef?.itemID })
        guard seasonIDs.count > 1 else {
            railDividerLabels = [:]
            return episodes.map { .episode($0.ref.itemID) }
        }
        var items: [BelowFoldItem] = []
        var labels: [String: String] = [:]
        var prevSeasonID: String?
        var seen: Set<String> = []
        for ep in episodes {
            if let sid = ep.parentRef?.itemID {
                if let prev = prevSeasonID, prev != sid, !seen.contains(sid) {
                    labels[sid] = Self.dividerLabel(for: ep)
                    items.append(.seasonDivider(sid))
                    seen.insert(sid)
                }
                prevSeasonID = sid
            }
            items.append(.episode(ep.ref.itemID))
        }
        railDividerLabels = labels
        return items
    }

    private static func dividerLabel(for episode: MediaItem) -> String {
        guard let n = episode.seasonNumber else { return "·" }
        return n == 0 ? "SP" : "S\(n)"
    }

    /// season ref itemID → chip label ("S3" / "SP"), for the divider cells.
    private var railDividerLabels: [String: String] = [:]

    /// The flat rail's items: episodes plus any season dividers.
    private var cachedEpisodes: [BelowFoldItem] = []
    private var cachedTrailers: [BelowFoldItem] = []
    private var cachedExtras: [BelowFoldItem] = []
    private var cachedRelated: [BelowFoldItem] = []
    /// Ordered Related items backing the shelf (index == shelf tile index).
    private var relatedItems: [MediaItem] = []
    private var cachedMoreLikeThis: [BelowFoldItem] = []
    /// Ordered More Like This items backing the shelf (metadata-only items).
    private var moreLikeThisItems: [MediaItem] = []
    /// TMDB watch/providers (metadata-only items). nil = no section.
    private var watchAvailability: MediaWatchAvailability?
    /// Cross-server check (metadata-only items). nil = no section (owned item).
    private var serverAvailability: ServerAvailability?
    /// The collection row (Plex's hub title, members, optional trailing
    /// collection tile). nil or no members: no row.
    private var collectionRow: CollectionRow?
    /// Each poster shelf's resting horizontal offset, so a content reload or
    /// a reused host cell does not throw the row back to its first tile.
    private var shelfOffsets: [BelowFoldSectionKind: CGFloat] = [:]
    private var cachedCastOrder: [(String, BelowFoldItem)] = []

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<BelowFoldSectionKind, BelowFoldItem>()
        sectionKinds = []
        func add(_ kind: BelowFoldSectionKind, _ items: [BelowFoldItem]) {
            snapshot.appendSections([kind]); snapshot.appendItems(items, toSection: kind); sectionKinds.append(kind)
        }
        // Order, minus whatever's absent: Episodes (shows), Cast & Crew, On
        // Your Servers (with Where to Watch, the other "where is it" block, for
        // unowned titles), About (synopsis and ratings), Trailers & Extras,
        // the Collection and More Like This rows, the Information footer, and
        // Related at the very bottom. The FIRST section present is the
        // primary peek row (the big peek inset in makeLayout). On Your Servers
        // shows on every Plex title.
        if !cachedEpisodes.isEmpty { add(.episodes, cachedEpisodes) }
        if !cachedCastOrder.isEmpty { add(.cast, cachedCastOrder.map { $0.1 }) }
        if serverAvailability != nil { add(.servers, [.servers]) }
        // Where to Watch and More Like This are TMDB's, for unowned titles only.
        if let avail = watchAvailability, !avail.options.isEmpty { add(.whereToWatch, [.whereToWatch]) }
        // About and Information only with the full detail (the episodes-only
        // peek load has none).
        if detail != nil { add(.about, [.about]) }
        if !cachedTrailers.isEmpty { add(.trailers, cachedTrailers) }
        if !cachedExtras.isEmpty { add(.extras, cachedExtras) }
        if let row = collectionRow, !row.members.isEmpty { add(.collection, [.collectionShelf]) }
        if !cachedMoreLikeThis.isEmpty { add(.moreLikeThis, cachedMoreLikeThis) }
        if detail != nil { add(.info, [.info]) }
        if !cachedRelated.isEmpty { add(.related, cachedRelated) }
        dataSource.apply(snapshot, animatingDifferences: false)
        // The primary peek row is section 0 (when any content exists). Drives the
        // focus-scroll "top section" logic for episodes OR a movie's related row.
        collectionView.topSectionIndex = sectionKinds.isEmpty ? nil : 0
        updateStaticSections()
    }

    /// Reset scroll to the rest (peek) position — used on collapse. Rest offset
    /// is -contentInset.top (= -detailsTopY); the episodes peek at the bottom via
    /// the episodes-section top inset.
    /// Scroll the episode rail so the first episode of the given season sits at
    /// the leading edge — ATV+ jumps the rail to that season when its pill is
    /// focused. Focus stays on the pill (this only moves the orthogonal scroller).
    func scrollEpisodesToSeason(seasonRefID: String) {
        guard let epSection = sectionKinds.firstIndex(of: .episodes) else { return }
        guard let itemIdx = cachedEpisodes.firstIndex(where: {
            if case let .episode(id) = $0, let ep = episodesByID[id] {
                return ep.parentRef?.itemID == seasonRefID
            }
            return false
        }) else { return }
        scrollOrthogonalEpisodes(toItem: itemIdx, epSection: epSection, animated: true)
    }

    /// On load, position the rail at the carousel item's own episode (or, for a
    /// season, that season's first episode) and make it the initial focus target,
    /// so opening an episode/season lands on its season in view — not season 0/1.
    /// The actual positioning is done in `layoutSubviews` (instant, before the
    /// first render) so the user never sees it scroll there.
    func scrollToInitialEpisode(item: MediaItem) {
        guard let epSection = sectionKinds.firstIndex(of: .episodes) else { return }
        let targetIdx: Int?
        switch item.kind {
        case .episode:
            targetIdx = cachedEpisodes.firstIndex(where: {
                if case let .episode(id) = $0 { return id == item.ref.itemID }
                return false
            })
        case .season:
            targetIdx = cachedEpisodes.firstIndex(where: {
                if case let .episode(id) = $0, let ep = episodesByID[id] {
                    return ep.parentRef?.itemID == item.ref.itemID
                }
                return false
            })
        default:
            return
        }
        guard let idx = targetIdx, idx > 0 else { return }
        let target = IndexPath(item: idx, section: epSection)
        pendingInitialScroll = target
        // Land focus here on the first Down into the rail (else the engine focuses
        // item 0 and scrolls back, undoing this).
        pendingInitialFocus = target
        currentSeasonFirstEpisode = target
        // Position within this layout pass so the rail is already there on the
        // first render. If the orthogonal scroller isn't built yet, layoutSubviews
        // retries each pass until it is — always before the frame is shown.
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Drive the orthogonal episode scroller's contentOffset.x to a given episode.
    /// Returns false if the scroller doesn't exist yet (caller may retry).
    @discardableResult
    private func scrollOrthogonalEpisodes(toItem itemIdx: Int, epSection: Int, animated: Bool) -> Bool {
        // Remember this as the Down-from-pills focus target.
        currentSeasonFirstEpisode = IndexPath(item: itemIdx, section: epSection)

        // An orthogonal compositional section scrolls in its OWN embedded scroll
        // view, which `collectionView.scrollToItem` does not drive. Drive that
        // scroller's contentOffset.x directly.
        guard let scroller = orthogonalScrollView(forSection: epSection) else { return false }

        // The section's leading inset is the scroller's contentInset, so its
        // natural resting offset is -contentInset.left (NOT 0).
        let base = -scroller.contentInset.left
        let layout = collectionView.collectionViewLayout
        let delta: CGFloat
        if let attrTarget = layout.layoutAttributesForItem(at: IndexPath(item: itemIdx, section: epSection)),
           let attrFirst = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: epSection)) {
            delta = attrTarget.frame.minX - attrFirst.frame.minX
        } else {
            // Fallback for when the attributes aren't built yet. It cannot assume
            // a fixed pitch any more: the rail mixes episode cards with slimmer
            // season dividers, so sum the actual widths up to the target.
            delta = cachedEpisodes.prefix(itemIdx).reduce(CGFloat(0)) { acc, railItem in
                if case .seasonDivider = railItem { return acc + SeasonDividerCell.cardWidth + Self.episodeGap }
                return acc + Self.episodeWidth + Self.episodeGap
            }
        }
        let maxX = max(base, scroller.contentSize.width - scroller.bounds.width + scroller.contentInset.right)
        let clampedX = min(max(base, base + delta), maxX)
        scroller.setContentOffset(CGPoint(x: clampedX, y: scroller.contentOffset.y), animated: animated)
        return true
    }

    /// The embedded UIScrollView backing an orthogonal compositional section.
    /// Found via a currently-visible cell in that section (walk up to the nearest
    /// UIScrollView that isn't the collection view itself).
    private func orthogonalScrollView(forSection section: Int) -> UIScrollView? {
        guard let ip = collectionView.indexPathsForVisibleItems.first(where: { $0.section == section }),
              let cell = collectionView.cellForItem(at: ip) else { return nil }
        var v: UIView? = cell.superview
        while let cur = v {
            if let sv = cur as? UIScrollView, sv !== collectionView { return sv }
            v = cur.superview
        }
        return nil
    }

    func resetScroll() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -Self.detailsTopY), animated: false)
    }

    /// Screen-y where the first episode lands in details (under the logo + the
    /// season-pills row, per the ATV+ reference). Also the collection's
    /// contentInset.top, so the focus engine aligns the focused episode here.
    static let detailsTopY: CGFloat = 230

    /// The `onScroll` value when the episodes sit at their details-rest (topBand)
    /// position — i.e. where the season-pills row is at its resting Y. Above this
    /// the pills scroll UP with the rail; below it (entry/collapse) they follow it
    /// down. Equals the episodes section's top inset (the carousel peek).
    var detailsRestOff: CGFloat { max(0, bounds.height - Self.episodePeek - Self.detailsTopY) }

    /// Whether focus is on the episodes (top) row vs a lower section. Drives the
    /// Up handler: episodes → pills; lower section → let the engine move up.
    var focusIsOnEpisodes: Bool { collectionView.focusedCellIsTopSection }
    /// True briefly after the episode thumb took focus (same-press guard for the
    /// thumb → season-pills lift). Covers BOTH coming up from a lower row AND
    /// coming up from the description (a within-row move the section-based guard
    /// `episodesJustTookFocus` misses).
    var episodeThumbJustTookFocus: Bool { CACurrentMediaTime() - lastThumbFocusTime < 0.06 }
    /// True while focus is on an episode description (vs a thumb). The VC uses
    /// this to redirect Left/Right to the adjacent episode's thumb.
    var episodeDescriptionFocused: Bool { collectionView.focusedViewIsEpisodeDescription }
    /// One-shot preferred-focus override: the engine focuses this episode cell's
    /// thumb on the next focus update (used for the description→adjacent-thumb
    /// redirect). Cleared by the caller after the update.
    private var armedEpisodeFocusIndexPath: IndexPath?

    /// Arm focus on the episode thumb adjacent (Left/Right) to the focused
    /// description, and reveal it in the orthogonal row. The VC then triggers the
    /// focus update. Returns false if there's no adjacent episode.
    func armAdjacentEpisodeThumb(forward: Bool) -> Bool {
        guard let epSection = sectionKinds.firstIndex(of: .episodes),
              let current = collectionView.focusedEpisodeIndexPath,
              current.section == epSection else { return false }
        let count = collectionView.numberOfItems(inSection: epSection)
        // Step OVER season dividers. They occupy rail indices but are not focus
        // stops, so a bare ±1 would arm focus on one and the update would land
        // nowhere.
        func isDivider(_ i: Int) -> Bool {
            guard i >= 0, i < cachedEpisodes.count else { return false }
            if case .seasonDivider = cachedEpisodes[i] { return true }
            return false
        }
        var targetItem = current.item + (forward ? 1 : -1)
        while isDivider(targetItem) { targetItem += forward ? 1 : -1 }
        guard targetItem >= 0, targetItem < count else { return false }
        armedEpisodeFocusIndexPath = IndexPath(item: targetItem, section: epSection)
        // No manual scroll: the engine scrolls the orthogonal row to the focused
        // thumb itself (minimal scroll-to-visible). There's a slight "catch-up"
        // beat when the target was off-screen — a known polish item; a deferred
        // (non-forced) focus update may coordinate the scroll better. Revisit.
        return true
    }

    /// Clear the one-shot armed target after the focus update has run.
    func clearArmedEpisodeFocus() { armedEpisodeFocusIndexPath = nil }

    /// True briefly after focus first lands on the episodes row — used to gate the
    /// episodes→pills jump against the same-press arrival from a lower row.
    var episodesJustTookFocus: Bool { collectionView.topSectionJustTookFocus }

    /// Timed slide of the episodes UP to the details-top position. Driven by a
    /// CADisplayLink (see animateOffsetY) so scrollViewDidScroll fires per frame
    /// and the hero choreography (blur + metadata fade + logo) rides this single
    /// movement in lockstep. Completion fires at the end.
    func slideToDetailsTop(animated: Bool, completion: (() -> Void)? = nil) {
        // Scroll so the first episode lands at detailsTopY — which is the focus
        // engine's preferred position (contentInset.top == detailsTopY), so
        // handing focus in afterward causes no re-scroll bounce.
        let targetY = max(0, bounds.height - Self.episodePeek - 2 * Self.detailsTopY)
        guard animated else { setOffsetY(targetY); completion?(); return }
        animateOffsetY(to: targetY, duration: 0.6, completion: completion)
    }

    /// Reverse of slideToDetailsTop: slide the episodes back down to the hero
    /// peek rest (drives the reverse choreography). Completion fires at the end.
    func slideToHeroRest(animated: Bool, completion: (() -> Void)? = nil) {
        let targetY = -Self.detailsTopY
        guard animated else { setOffsetY(targetY); completion?(); return }
        animateOffsetY(to: targetY, duration: 0.6, completion: completion)
    }

    // MARK: - One-clock vertical scroll (CADisplayLink)

    // UIView.animate { contentOffset = } fires scrollViewDidScroll only ONCE
    // (with the final value) — verified by trace — so a hero fade riding the
    // scroll delegate would SNAP. A CADisplayLink that sets contentOffset every
    // frame fires scrollViewDidScroll per frame, so the rail slide and the hero
    // fade run on a SINGLE clock, in lockstep (the one-morph-one-clock rule).
    private var offsetLink: CADisplayLink?
    private var offsetStartY: CGFloat = 0
    private var offsetTargetY: CGFloat = 0
    private var offsetStartTime: CFTimeInterval = 0
    private var offsetDuration: CFTimeInterval = 0.6
    private var offsetCompletion: (() -> Void)?

    private func setOffsetY(_ y: CGFloat) {
        collectionView.contentOffset.y = y
    }

    private func animateOffsetY(to targetY: CGFloat, duration: CFTimeInterval, completion: (() -> Void)?) {
        // Supersede any in-flight scroll; drop its completion (don't double-fire).
        offsetLink?.invalidate()
        offsetLink = nil
        offsetCompletion = nil
        offsetStartY = collectionView.contentOffset.y
        offsetTargetY = targetY
        offsetDuration = max(0.0001, duration)
        offsetCompletion = completion
        offsetStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepOffset))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    @objc private func stepOffset(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - offsetStartTime
        let t = min(1, max(0, elapsed / offsetDuration))
        // Quadratic ease-in-out — visually matches UIView's .curveEaseInOut.
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        setOffsetY(offsetStartY + (offsetTargetY - offsetStartY) * CGFloat(eased))
        guard t >= 1 else { return }
        link.invalidate()
        offsetLink = nil
        let done = offsetCompletion
        offsetCompletion = nil
        done?()
    }

    deinit { offsetLink?.invalidate() }

    // MARK: - Season-pill → episodes focus entry

    /// The selected season's first episode, updated on each pill scroll. When the
    /// user presses Down from the season pills, focus must land on THIS episode —
    /// not the collection's remembered index path (still episode 0 / season 1),
    /// which would snap the rail back and re-select season 1.
    private var currentSeasonFirstEpisode: IndexPath?
    /// Armed (by the Down-from-pills handler) only for the synchronous focus
    /// update, so normal episode navigation still uses the remembered index path.
    var pillEntryArmed = false
    /// The carousel item's episode, positioned in `layoutSubviews` before first
    /// render so the rail opens on the right season with no visible scroll.
    private var pendingInitialScroll: IndexPath?
    /// One-shot: the episode the first Down-into-rail should focus (the carousel
    /// item's), so the engine doesn't focus item 0 and scroll the rail back.
    /// Cleared once focus lands on an episode.
    private var pendingInitialFocus: IndexPath?
    func clearPendingInitialFocus() { pendingInitialFocus = nil }

    // MARK: - UICollectionViewDelegate

    /// Episodes and trailers host their own focusable subviews (thumb +, for
    /// episodes, the description). The cell itself must be non-focusable so the
    /// focus engine targets those subviews directly — giving episodes two focus
    /// stops and trailers one (the thumb). All other sections stay whole-cell.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .episode, .trailer, .extra: return false
        // Same answer for a different reason: the others defer to focusable
        // subviews, the divider has none and is never a focus stop at all.
        case .seasonDivider: return false
        // The footer's three columns are the focus stops, not the cell.
        case .info: return false
        default: return true
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // Cast / crew cell Select → open the person detail page.
        if case let .cast(id) = dataSource.itemIdentifier(for: indexPath),
           let entry = castEntriesByID[id] {
            onSelectPerson?(entry.person)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let off = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        onScroll?(max(0, off))
    }

    /// If focus was inside a shelf-host row (Related) when a modal went up,
    /// put that row back on the tile it was on and arm it as the focus target.
    ///
    /// Must run BEFORE the focus update resolves. `indexPathForPreferredFocusedView`
    /// can't do this itself: it's a pure query called mid-update, and returning
    /// the host cell's path would hand focus to the nested collection, which
    /// restarts at item 0.
    func restoreShelfRowFocusIfNeeded(requestingFocus: Bool = true) {
        // The collection's last focused index path names the ROW (a shelf row is
        // ONE cell, so every tile in it shares that path); the tile index lives
        // on the row itself (`lastFocusedItemIndex`). Do not pick the first
        // visible shelf with a tile index instead: `ShelfRowCell` clears it only
        // in `prepareForReuse`, so with Collection and Related both on screen
        // the row focus left earlier can still carry one and win.
        guard let path = collectionView.lastFocusedIndexPath,
              let shelf = collectionView.cellForItem(at: path) as? ShelfRowCell,
              let item = shelf.lastFocusedItemIndex else { return }
        // The row's target cell may not be realized yet (the trace showed
        // cellRealized=false), and prepareFocusRestore silently no-ops when it
        // can't find the cell. Lay the collection out first so the tile exists.
        collectionView.layoutIfNeeded()
        // Position the row's horizontal window and arm the tile...
        if requestingFocus {
            shelf.prepareFocusRestore(on: item)
        } else {
            shelf.armFocusRestore(on: item)
        }
        // ...and route the pending focus update INTO this cell, so the engine
        // asks the row which tile it wants instead of picking the first
        // focusable cell in the whole collection (the primary row).
        armedShelfRestoreCell = shelf
        // Vertical position is NOT set here on purpose: the collection's own
        // didUpdateFocus drives that off the newly focused cell, and adding a
        // second scroll driver here would fight it mid-flight.
    }

    /// Clear the one-shot shelf restore target once focus has resolved.
    func clearArmedShelfRestore() { armedShelfRestoreCell = nil }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        // Order matters: the armed/pending targets are one-shot intents for a
        // specific interaction and must win. `lastFocusedIndexPath` is the
        // last-resort restore after a modal (playing a trailer, an extra, or
        // anything on Related) — without it the engine picks for itself and
        // lands on item 0 of the first row.
        let candidate = armedEpisodeFocusIndexPath
            ?? pendingInitialFocus
            ?? (pillEntryArmed ? currentSeasonFirstEpisode : nil)
            ?? self.collectionView.lastFocusedIndexPath
        guard let candidate else { return nil }
        return realizedFocusTarget(candidate, in: collectionView)
    }

    /// UIKit requires that this delegate return an index path whose CELL EXISTS
    /// right now — not merely a valid data-source index. Episodes live in an
    /// orthogonal scrolling section, so a target deep in the rail (say episode
    /// 22) has no cell until that part of the rail is scrolled into view, and
    /// returning it raises:
    ///
    ///     NSInternalInconsistencyException: no cell for index path {0, 21} —
    ///     the collection view's delegate must return an index path for a valid
    ///     UICollectionViewCell
    ///
    /// So: drop paths that are stale or not yet realized, and return nil to let
    /// the focus engine pick. This is a pure query — UIKit calls it mid focus
    /// update, so it must not scroll, lay out, or mutate our tracking state.
    /// Realizing the cell is the job of `pendingInitialScroll` in
    /// `layoutSubviews`, which runs before focus is handed in.
    private func realizedFocusTarget(_ indexPath: IndexPath, in collectionView: UICollectionView) -> IndexPath? {
        // Stale across a snapshot change — the item may no longer exist at all.
        guard dataSource.itemIdentifier(for: indexPath) != nil else { return nil }
        // Deep episodes live in an orthogonal rail and have no cell until that
        // stretch is scrolled in. Preferring an unrealized path is the crash.
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }

        // A shelf-host row (Related) is ONE full-width cell hosting its own
        // nested collection, so this index path identifies the ROW, not the
        // tile that was focused. Preferring the host hands focus to the nested
        // collection, which starts over at its first item — and because Related
        // sits below the primary peek row, the resulting focus scroll reads as
        // "focus jumped up to Trailers". Restore inside the row instead.
        // (This method is a pure query — see the note above — so returning the
        // host cell's path is not an option and neither is scrolling the row
        // here. `restoreShelfRowFocusIfNeeded` does that work before the focus
        // update, and by the time we're asked the row is already positioned;
        // the nested cell's own preferredFocusEnvironments then lands the tile.)
        if cell is ShelfRowCell { return nil }
        return indexPath
    }
}

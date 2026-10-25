// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewCarouselViewController.swift
//  Rivulet
//
//  UIKit replacement for `PreviewOverlayHost` + the surrounding
//  `PreviewContainerViewController` modal. Hosts a UICollectionView
//  with a custom `PreviewCarouselLayout` that gives every cell a
//  parallax-aware frame, then drives `contentOffset` directly via
//  `UIViewPropertyAnimator` for paging with the exact cubic timing
//  curve from the SwiftUI baseline.
//
//  Entry / dismiss morphs use a separate `morphSnapshot` view: a
//  PreviewCardView at the same size as the source poster tile,
//  morphed via spring to the centered carousel frame. The collection
//  view sits behind it and is revealed by a crossfade once the
//  morph completes.
//  UIKit home rows can also pass snapshots for every visible source tile.
//  Those snapshots animate into the carousel's visible card frames together,
//  so the row reads as enlarging into the carousel instead of a modal
//  appearing over it.
//
//  Visual goals:
//   - Smooth 60fps paging with parallax (artwork lags the card).
//   - No content swap mid-animation — every cell shows its item
//     throughout its visible lifetime.
//   - Entry + dismiss morphs run on Apple's shelf-tile spring.
//

import Combine
import Sentry
import UIKit
import os.log

private let previewCarouselLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCarouselUIKit"
)

final class PreviewCarouselViewController: UIViewController {
    // MARK: - Inputs

    private var items: [MediaItem]
    private(set) var selectedIndex: Int
    private let initialSourceFrame: CGRect
    private let entrySnapshots: [PreviewEntrySnapshot]
    private let sourceItemIDs: [String]?
    private let onPrepareDismiss: (PreviewSourceTarget?) -> Void
    private let onDismiss: (PreviewSourceTarget?) -> Void
    private var dismissSourceTarget: PreviewSourceTarget?
    /// The source row's tiles as they are now, for the exit after paging.
    var freshEntrySnapshots: ((PreviewSourceTarget?) -> [PreviewEntrySnapshot])?
    /// Runs once however the carousel goes away: the presenter un-hides its tiles.
    var onTeardown: (() -> Void)?

    // MARK: - State

    private(set) var state = PreviewStateMachine()
    private var hasRunEntryMorph = false
    private var hasPreparedEntrySnapshots = false
    private var didStandaloneExpand = false

    /// Clipping windows wrapping each entry snapshot. The morph animates
    /// these, not the snapshots (see EntryMorphWindowView). Parallel to
    /// `entrySnapshots` rather than keyed by item index, so repeated indices
    /// each keep their own window instead of one silently replacing another.
    private var entryMorphWindows: [(window: EntryMorphWindowView, itemIndex: Int, sourceFrame: CGRect)] = []

    /// CADisplayLink-driven paging state. Replaces UIViewPropertyAnimator
    /// because UIVPA's contentOffset interpolation doesn't trigger
    /// per-frame layout invalidation, which breaks parallax and
    /// off-screen cell pre-allocation.
    private struct PagingAnimation {
        let startOffset: CGFloat
        let endOffset: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let targetIndex: Int
    }
    private var pagingAnimation: PagingAnimation?
    private var displayLink: CADisplayLink?

    /// Up/down swipe recognizers (touch surface). Held so the gesture delegate
    /// can tell them apart from the horizontal paging swipes, which are claimed
    /// unconditionally.
    private var verticalSwipeRecognizers: [UISwipeGestureRecognizer] = []
    /// Whether focus rested on the details' top row when the current touch began.
    /// A long swipe from a lower row walks focus up to it mid-gesture, and must not
    /// then also collapse the details when the swipe completes.
    private var touchBeganOnDetailsTopRow = false

    // MARK: - Subviews

    private let backdrop = UIView()
    private let layout = PreviewCarouselLayout()
    private let expandedLayout = PreviewExpandedLayout()
    private var morphController: CarouselMorphController!
    private var collectionView: PinnableCollectionView!

    /// VC-owned backdrop plane — single source of truth for artwork.
    /// Sits behind the collection view; cells are transparent windows.
    private let backdropPlane = BackdropPlaneView()

    /// Invisible, always-focusable anchor. The carousel has no focusable
    /// cells (canFocusItemAt is false everywhere), and on tvOS PRESS EVENTS
    /// ARE DELIVERED TO THE FOCUSED VIEW and climb the responder chain from
    /// there — NOT to the first responder, and never to children of the
    /// focused view (WWDC 2016/210; UIKIT_FOUNDATIONS §2). With nothing
    /// focused inside this modal, Menu presses never enter our responder
    /// chain at all, so neither the .menu gesture recognizer nor presses*
    /// overrides ever fire — the presentation machinery handles Menu as a
    /// default modal-dismiss one layer up. This anchor gives the focus
    /// engine a target so the Menu press reaches our chain; the recognizer
    /// then "begins", emits pressesCancelled up the chain (which suppresses
    /// the system dismiss), and our handler runs collapse-vs-dismiss.
    private let focusAnchor = PreviewFocusAnchorView()

    /// Temporary card view used for the source-frame → centered-frame
    /// entry morph (and the reverse for dismiss). Sits on top of the
    /// collection view until the entry settles, then fades out as
    /// the real collection-view cell becomes visible underneath.
    private let morphSnapshot = PreviewCardView(frame: .zero)

    /// Source tile snapshots captured from the presenting row. These sit above
    /// the hidden live carousel during entry, animate to carousel card frames,
    /// then fade out as the real backdrop plane + cells fade in.
    private let entrySnapshotContainer = UIView()

    /// Below-fold detail surface. Sits ABOVE the collection view (which holds
    /// the hero chrome) and wakes up only after the expand morph completes.
    /// Hidden + non-interactive in carousel mode. Drives its own scroll
    /// choreography; calls back via `onScrollProgress` so the VC can fade the
    /// two layers it owns (the backdrop blur + the cell chrome).
    private let expandedDetail = ExpandedDetailContainerView()

    /// Backdrop blur that fades in as the user scrolls into the below-fold.
    /// Sits BELOW the chrome (blurs the artwork; chrome fades on top of it).
    /// Intensity is scrubbed via a paused property animator's
    /// `fractionComplete` (Iter 3) — NOT alpha (Apple: alpha on an effect
    /// view artifacts).
    private let blurOverlay = UIVisualEffectView(effect: nil)
    /// Paused animator whose `fractionComplete` is the blur intensity. Built
    /// lazily when the blur is first armed (Iter 3).
    private var blurAnimator: UIViewPropertyAnimator?

    deinit {
        // A UIViewPropertyAnimator THROWS in dealloc if released while still in
        // the .active state. `blurAnimator` uses pausesOnCompletion = true, so it
        // sits in .active (paused) for the controller's whole life — it must be
        // stopped before the controller is torn down or the app aborts on dismiss.
        if blurAnimator?.state == .active { blurAnimator?.stopAnimation(true) }
        onTeardown?()
    }

    private func teardown() {
        onTeardown?()
        onTeardown = nil
    }

    /// Whether the centered card is currently in expanded layout.
    /// In `.expandingHero`/`.expandedHero`/`.detailsStable` this is
    /// true. Drives the custom layout (see `PreviewCarouselLayout`)
    /// to size the centered cell to fullscreen and hide side peeks.
    /// The cell's existing `chromeView` is the SAME view in both
    /// states: only its constraint constants animate (the chrome inset)
    /// and the panel's corner radius animates to 0. No
    /// reparenting, no second view tree, true visual continuity.
    private(set) var isExpanded: Bool = false

    /// True while a Down/Up below-fold scroll animation is in flight. Guards
    /// against overlapping scroll commands.
    private var isDetailScrolling = false

    /// Watch-state refresh subscription (issue #228) — same signal Home uses.
    private var refreshObservers = Set<AnyCancellable>()
    /// Bumped per refresh so a slow fetch from an earlier notification can't
    /// overwrite a newer one (or land after the user paged away).
    private var watchRefreshToken: UInt64 = 0

    // MARK: - Lifecycle

    /// Standalone "expanded detail" mode: seeded with a single item, opens
    /// already expanded (no carousel-stable browse, no paging), blur-fades in/out,
    /// and Menu dismisses the whole thing. Used to show a movie/show's full detail
    /// when drilled into (e.g. a Related poster) without building a second VC.
    private let standaloneDetail: Bool
    private let blurFade = BlurFadeTransitioningDelegate()

    init(
        items: [MediaItem],
        selectedIndex: Int,
        sourceFrame: CGRect,
        sourceTarget: PreviewSourceTarget?,
        entrySnapshots: [PreviewEntrySnapshot] = [],
        sourceItemIDs: [String]? = nil,
        standaloneDetail: Bool = false,
        onPrepareDismiss: @escaping (PreviewSourceTarget?) -> Void = { _ in },
        onDismiss: @escaping (PreviewSourceTarget?) -> Void
    ) {
        precondition(!items.isEmpty, "PreviewCarouselViewController requires at least one item")
        precondition(selectedIndex >= 0 && selectedIndex < items.count, "selectedIndex out of range")
        self.items = items
        self.selectedIndex = selectedIndex
        self.initialSourceFrame = sourceFrame
        self.entrySnapshots = entrySnapshots
        self.sourceItemIDs = sourceItemIDs?.count == items.count ? sourceItemIDs : nil
        self.onPrepareDismiss = onPrepareDismiss
        self.dismissSourceTarget = sourceTarget
        self.standaloneDetail = standaloneDetail
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        if standaloneDetail {
            // Blur-fade in/out over whatever's behind (the previous detail), and
            // keep it visible — this is presented over another modal.
            self.modalPresentationStyle = .overFullScreen
            self.transitioningDelegate = blurFade
            return
        }
        // Keep the presenter alive behind us. The row-entry and row-exit
        // morphs need Home visible while source tile snapshots animate into
        // and out of the carousel. The explicit `backdrop` view below owns
        // the black surround and fades it in/out on the morph timeline.
        //
        // NOTE: presentation style does NOT control Menu dismissal. Menu flows
        // up the responder chain via pressesEnded reaching UIApplication
        // regardless of style. We own Menu by claiming first responder
        // (canBecomeFirstResponder + becomeFirstResponder in viewDidAppear) and
        // absorbing the press in our handler. See §2.
        self.modalPresentationStyle = .overFullScreen
        self.restoresFocusAfterTransition = false
        // No modal transition — the entry morph IS the transition.
        // The caller presents with animated: false so viewDidAppear
        // fires immediately for the spring animator.
        self.modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCarouselViewController is not Storyboard-backed")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        if !standaloneDetail { preloadEntryBackdrops() }

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        // Apple's surround grey; shows in the top strip and the gaps between cards.
        backdrop.backgroundColor = UIColor(white: 0.16, alpha: 1)
        backdrop.alpha = entrySnapshots.isEmpty ? 1 : 0

        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Backdrop plane sits behind the collection view (z-order:
        // backdrop-color -> plane -> collection view) so cells layer on top.
        backdropPlane.translatesAutoresizingMaskIntoConstraints = false
        backdropPlane.configure(items: items)
        view.addSubview(backdropPlane)
        NSLayoutConstraint.activate([
            backdropPlane.topAnchor.constraint(equalTo: view.topAnchor),
            backdropPlane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropPlane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropPlane.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Backdrop blur sits above the plane (artwork), below the collection
        // view (chrome). Hidden until armed by the scroll choreography (Iter 3).
        blurOverlay.translatesAutoresizingMaskIntoConstraints = false
        blurOverlay.isUserInteractionEnabled = false
        blurOverlay.isHidden = true
        view.addSubview(blurOverlay)
        NSLayoutConstraint.activate([
            blurOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            blurOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        layout.itemCount = items.count
        collectionView = PinnableCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.bounces = false
        collectionView.isScrollEnabled = false  // We drive offset manually.
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(
            PreviewCardView.self,
            forCellWithReuseIdentifier: PreviewCardView.reuseIdentifier
        )
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        entrySnapshotContainer.translatesAutoresizingMaskIntoConstraints = false
        entrySnapshotContainer.isUserInteractionEnabled = false
        entrySnapshotContainer.isHidden = entrySnapshots.isEmpty
        view.addSubview(entrySnapshotContainer)
        NSLayoutConstraint.activate([
            entrySnapshotContainer.topAnchor.constraint(equalTo: view.topAnchor),
            entrySnapshotContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            entrySnapshotContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            entrySnapshotContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Below-fold detail surface above the collection view (chrome). Hidden
        // and inert until the expand morph completes. Full-screen; it manages
        // its own internal translation. onScrollProgress is wired in Iter 3 to
        // drive the blur + cell-chrome fade.
        expandedDetail.translatesAutoresizingMaskIntoConstraints = false
        expandedDetail.isHidden = true
        view.addSubview(expandedDetail)
        NSLayoutConstraint.activate([
            expandedDetail.topAnchor.constraint(equalTo: view.topAnchor),
            expandedDetail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            expandedDetail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            expandedDetail.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // Scroll-into-details choreography the VC owns: backdrop blur + the
        // hero metadata (cell chrome) fade. Driven by the below-fold's scroll
        // progress (0→1 over reserveDistance).
        expandedDetail.onScrollProgress = { [weak self] progress in
            self?.driveHeroLayers(progress)
        }
        expandedDetail.onSelectSynopsis = { [weak self] detail in
            guard let self else { return }
            let content = InfoPopupContent.description(
                title: detail.item.title,
                subtitle: detail.genres.prefix(3).joined(separator: ", "),
                body: detail.item.overview)
            self.present(InfoPopupViewController(content: content, width: 840, scrollable: true), animated: true)
        }
        expandedDetail.onSelectAdvisory = { [weak self] advisory in
            let content = InfoPopupContent.advisory(advisory)
            self?.present(InfoPopupViewController(content: content, width: 720, scrollable: true), animated: true)
        }
        // Episode thumb Select → play the episode.
        expandedDetail.onPlayEpisode = { [weak self] episode in
            self?.playMediaItem(episode)
        }
        // Trailer / extra Select → play that video. Routed on the
        // extra's playbackKey, NOT its id: IVA extras have no library ratingKey.
        expandedDetail.onPlayTrailer = { [weak self] trailer in
            self?.presentExtraPlayer(trailer)
        }
        // Episode description Select → reusable detail page (blur-fade in Stage 3c).
        expandedDetail.onShowEpisodeDetails = { [weak self] episode in
            guard let self else { return }
            // seriesTitle nil for now — the show name comes from the episode's
            // fetched metadata (grandparentTitle) in Stage 3b, not the carousel's
            // selectedIndex item (which isn't reliably the show).
            let page = MediaItemDetailPageViewController(
                item: episode,
                seriesTitle: nil,
                onPlay: { [weak self] ep, sourceID in self?.playMediaItem(ep, sourceID: sourceID) })
            self.present(page, animated: true)
        }

        // Related poster Select → the item's FULL expanded detail (movies/shows
        // always have trailers/extras/related below the fold), presented standalone
        // (no carousel) with a blur-fade. NOT the episode-only "just details" page.
        expandedDetail.onShowRelatedDetails = { [weak self] item in
            self?.presentStandaloneDetail(item)
        }

        // Season pill Select → the season's own title-first detail page (the
        // same page an episode's description opens), NOT another standalone
        // carousel detail: that page re-hosted the pills over a one-season rail,
        // so from there every season needed a click and each click stacked
        // another carousel. Focus already switched the rail's season; the press
        // opens the season's summary and info on top of the show.
        expandedDetail.onOpenSeason = { [weak self] season in
            guard let self else { return }
            let show = self.items.indices.contains(self.selectedIndex) ? self.items[self.selectedIndex] : nil
            let page = MediaItemDetailPageViewController(
                item: season,
                seriesTitle: show?.kind == .show ? show?.title : nil,
                // playHeroItem, not playMediaItem: a season key has no media, so
                // Play must resolve to its first unplayed episode.
                onPlay: { [weak self] season, _ in self?.playHeroItem(season) })
            self.present(page, animated: true)
        }
        // On Your Servers card Select → the page switches to that server's
        // copy and focus goes back up to its Play button. Nothing plays yet.
        expandedDetail.onSelectServerCopy = { [weak self] copyID in
            guard let self else { return }
            (self.collectionView.cellForItem(at: IndexPath(item: self.selectedIndex, section: 0)) as? PreviewCardView)?
                .selectCopy(copyID: copyID)
            self.returnToHeroFromBelowFold()
        }
        // Cast / crew cell Select → person detail page (full-screen).
        expandedDetail.onSelectPerson = { [weak self] person in
            guard let self else { return }
            let page = PersonDetailViewController(person: person)
            page.onSelectItem = { [weak self] item in self?.presentPersonFilmographyItem(item) }
            self.present(page, animated: true)
        }

        expandedLayout.itemCount = items.count
        morphController = CarouselMorphController(
            collectionView: collectionView,
            backdropPlane: backdropPlane,
            carouselLayout: layout,
            expandedLayout: expandedLayout
        )
        // Let the below-fold peek's expand morph ride the morph animator.
        morphController.detailContainer = expandedDetail

        // Morph snapshot sits on top until entry settles.
        morphSnapshot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(morphSnapshot)

        // Own the Menu button via a press gesture recognizer on our own
        // view. This is the reliable mechanism (see UIKIT_FOUNDATIONS §2):
        // a Menu press on a present()-ed modal otherwise reaches the
        // presentation controller's dismiss path IN PARALLEL to the press
        // responder chain — so absorbing it in pressesBegan/Ended/Cancelled
        // is not enough (the press arrives as pressesCancelled when our
        // collapse triggers a focus update mid-press, and the modal
        // dismisses anyway). A .menu tap recognizer on this view intercepts
        // the press first, letting handleMenuPress() decide collapse vs
        // dismiss.
        let menuRecognizer = UITapGestureRecognizer(target: self, action: #selector(menuGestureFired))
        menuRecognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuRecognizer)

        // Swipe-to-page. Paging previously keyed ONLY off .leftArrow/.rightArrow
        // presses, which a touch surface does not emit — a light swipe produces
        // indirect touches plus focus-engine moves, and arrow presses come from
        // directional CLICKS. Because the carousel is deliberately focusless
        // (`canFocusItemAt` is false in .carouselStable), a swipe also generated
        // no focus move, so it did nothing on any remote. These recognizers give
        // the swipe a home. Only claimable while the carousel owns input
        // (gated in `gestureRecognizerShouldBegin`): in the expanded/detail
        // states the chrome action buttons ARE focusable, and a recognizer
        // that begins cancels the focus move a swipe should make between them.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleCarouselSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            // On tvOS a swipe recognizer otherwise waits for a .select press.
            swipe.allowedPressTypes = []
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }

        // Swipe-up/down. The vertical choreography (carousel → hero → details,
        // pills → episodes, and every step back up) lived only in `pressesBegan`
        // under .upArrow/.downArrow, so a touch-surface swipe reached none of it
        // and the engine bonked with no candidate to move to.
        //
        // Unlike the horizontal case these CANNOT be claimed unconditionally:
        // inside the details the below-fold rows ARE focusable, and the engine
        // needs the swipe to walk between them. `gestureRecognizerShouldBegin`
        // therefore lets each recognizer begin only for the hand-off transitions
        // the engine cannot perform on its own.
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleVerticalSwipe(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.allowedPressTypes = []
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
            verticalSwipeRecognizers.append(swipe)
        }

        // Focus anchor: invisible, always-focusable, so the focus engine has
        // a target inside the modal and Menu presses enter our responder
        // chain (see the focusAnchor doc comment). Zero-size, behind
        // everything; it never shows and never steals visible focus.
        focusAnchor.frame = .zero
        view.addSubview(focusAnchor)

        // Issue #228: the detail is all in-memory instance state seeded once in
        // `init`, so after the player dismissed it kept rendering the
        // pre-playback snapshot (hero AND episode rail). `.plexDataNeedsRefresh`
        // is the correctly-ordered signal — the player posts it only AFTER its
        // "stopped"/markAsWatched report has had time to commit server-side, so
        // a refetch on it reads the new state. (An `onDismiss` hook would fire
        // ~2s too early and read stale.) Same publisher Home subscribes to.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshWatchState()
            }
            .store(in: &refreshObservers)

        previewCarouselLog.info("[PCV] viewDidLoad items=\(self.items.count, privacy: .public) selected=\(self.selectedIndex, privacy: .public)")
        // NOTE: do NOT force collectionView.layoutIfNeeded() here. `view`
        // has no real frame yet at viewDidLoad time (it's sized by the
        // presentation controller AFTER this runs) — forcing a layout pass
        // against a zero-width view collapses every cell's internal Auto
        // Layout (logged "UIView-Encapsulated-Layout-Width == 0" warnings)
        // and leaves PreviewCardView's chrome permanently mis-laid-out for
        // that dequeue, since the diffable/flow layout caches attributes
        // from this first (wrong) pass. The real, bounds-valid layout pass
        // happens in viewDidLayoutSubviews(); cellForItemAt still runs
        // synchronously there before the entry morph reads cell content.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // `.fullScreen` presentation runs viewDidLayoutSubviews at least
        // once on a TRANSITIONAL pass before `view` has its real frame
        // (zero/garbage bounds). Writing `collectionView.contentOffset` in
        // that pass forces UICollectionView to lay out + dequeue cells
        // against those bad bounds, which collapses every PreviewCardView's
        // internal Auto Layout to zero width (logged as
        // "UIView-Encapsulated-Layout-Width == 0") and corrupts that
        // dequeue's chrome content for good — re-snapshotting it later
        // (entry/exit morphs) just captures the corrupted, zero-sized
        // content, which is why the carousel reads as black even though
        // entrySnapshots/backdropPlane/alpha timing are all correct.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        // Center the carousel on `selectedIndex` so the first frame
        // shows the chosen item under the morph snapshot. We do this
        // every layout pass because `collectionViewContentSize`
        // depends on bounds and `bounds` can change (orientation,
        // focus shifts).
        let offset = layout.contentOffsetCentered(index: selectedIndex)
        collectionView.contentOffset = offset

        if !isExpanded {
            syncCards()
        }

        // Position the morph snapshot. Pre-entry: at the source
        // frame. Post-entry: hidden anyway.
        if !hasRunEntryMorph {
            backdrop.alpha = entrySnapshots.isEmpty ? 1 : 0
            backdropPlane.alpha = 0
            collectionView.alpha = 0
            if entrySnapshots.isEmpty {
                morphSnapshot.isHidden = false
                morphSnapshot.translatesAutoresizingMaskIntoConstraints = true
                morphSnapshot.frame = initialSourceFrame == .zero
                    ? centeredFrameInWindow()
                    : view.convert(initialSourceFrame, from: nil)
                // Show item[selectedIndex] in the snapshot so the morph
                // is visually meaningful.
                morphSnapshot.item = items.indices.contains(selectedIndex)
                    ? items[selectedIndex]
                    : nil
            } else {
                morphSnapshot.isHidden = true
                prepareEntrySnapshotsIfNeeded()
            }
        }

        // Standalone detail (e.g. a Related drill-in): open ALREADY expanded,
        // once, now that bounds are valid — the blur-fade presents the expanded
        // detail with no spring/card-grow morph.
        if standaloneDetail, !didStandaloneExpand, view.bounds.width > 0 {
            didStandaloneExpand = true
            hasRunEntryMorph = true
            enterStandaloneExpanded()
        }
    }

    /// Standalone entry: reveal (no spring) + apply the expanded end-state
    /// instantly, mirroring `expandCurrentCard` but with no animation.
    private func enterStandaloneExpanded() {
        guard !isExpanded, items.indices.contains(selectedIndex) else { return }
        // Reveal — mirror the `.zero`-source entry (no spring, no snapshot).
        morphSnapshot.isHidden = true
        backdrop.alpha = 1
        collectionView.alpha = 1
        backdropPlane.alpha = 1
        state.completeEntryMorph()                 // entryMorph → carouselStable
        updateCurrentCellChrome(animated: false)   // sets expandedDetail.item + chrome
        collectionView.layoutIfNeeded()
        // Expand instantly.
        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        state.beginExpand()
        isExpanded = true
        cell?.setIsCurrent(true, animated: false)
        expandedDetail.setCurrent(true, animated: false)
        collectionView.pinnedOffsetX = collectionView.contentOffset.x
        morphController.expandInstantly(centeredIndex: selectedIndex, in: view.bounds, cell: cell) { [weak self] in
            guard let self else { return }
            self.state.finishExpand()
            self.expandedDetail.revealBelowFoldCollection()
            self.setNeedsFocusUpdate()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // In the scrolled-in details state, focus lives in the real below-fold
        // collection (focus-driven nav + auto-scroll). Otherwise focus the
        // invisible anchor so Menu presses are delivered into our responder
        // chain (tvOS routes presses to the FOCUSED view; without a target the
        // modal would Menu-dismiss by default).
        if state.phase == .detailsStable, let env = expandedDetail.belowFoldFocusEnvironment {
            return [env]
        }
        // Expanded hero: focus the centered cell, which redirects into the Play
        // pill. Falls back to the anchor until the detail (action row) loads.
        if state.phase == .expandedHero,
           let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView,
           cell.actionFocusEnvironment != nil {
            return [cell]
        }
        return [focusAnchor]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Drive focus to the anchor so the focus engine has a target inside
        // the modal. becomeFirstResponder is kept as belt-and-suspenders but
        // focus (not first-responder) is what makes presses reach us on tvOS.
        becomeFirstResponder()
        // If focus was inside a shelf-host row (Related) before a modal, put
        // the row back on that tile BEFORE the focus update resolves — the
        // host cell can't be preferred directly, so the row has to be
        // positioned and armed first. No-op unless a shelf row had focus.
        expandedDetail.restoreShelfRowFocusIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // One-shot: consumed by the update above, so it can't capture a later one.
        expandedDetail.clearArmedShelfRestore()
        guard !hasRunEntryMorph else { return }
        hasRunEntryMorph = true

        if !entrySnapshots.isEmpty {
            // The flight fades the poster into the card's backdrop: start it
            // once that backdrop is in hand (it began loading at viewDidLoad),
            // so the card never holds on the poster and then jumps. Capped,
            // so a slow server costs at most a beat before the flight.
            Task { @MainActor [weak self] in
                await self?.waitForEntryBackdrop(timeout: .milliseconds(450))
                self?.runRowEntryMorph()
            }
            return
        }

        if initialSourceFrame == .zero {
            // No source to morph from. Reveal the collection view
            // immediately and skip the spring.
            morphSnapshot.isHidden = true
            backdrop.alpha = 1
            collectionView.alpha = 1
            backdropPlane.alpha = 1
            state.completeEntryMorph()
            updateCurrentCellChrome(animated: false)
            return
        }

        let targetFrame = centeredFrameInWindow()

        let morpher = Self.makeShelfTransitionAnimator()
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            self.morphSnapshot.frame = targetFrame
            self.backdrop.alpha = 1
            self.backdropPlane.alpha = 1
            self.collectionView.alpha = 1
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            self.morphSnapshot.isHidden = true
            self.state.completeEntryMorph()
            // Cascade in the chrome on the centered cell.
            self.updateCurrentCellChrome(animated: true)
        }
        morpher.startAnimation()
    }

    /// Refresh the `isCurrent` flag on every visible cell so the
    /// center one (at `selectedIndex`) gets its chrome cascade and
    /// the peeks stay bare.
    ///
    /// `animated: true` fades the centre's chrome in (0.5s ease-in-out);
    /// `animated: false` snaps it.
    private func updateCurrentCellChrome(animated: Bool) {
        for cell in collectionView.visibleCells {
            guard let card = cell as? PreviewCardView else { continue }
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            let shouldBeCurrent = indexPath.item == selectedIndex
            card.setIsCurrent(shouldBeCurrent, animated: animated && shouldBeCurrent)
        }
        // Drive the below-fold peek for the centered card — it loads in WITH the
        // chrome cascade (P2: the peek is live in carousel-stable, not just
        // expanded). Item sync + cascade so paging snaps it out then re-cascades.
        expandedDetail.isHidden = false
        if items.indices.contains(selectedIndex) {
            expandedDetail.item = items[selectedIndex]
        }
        expandedDetail.setCurrent(true, animated: animated)
    }

    // MARK: - Geometry helpers

    /// Places (or re-places) the row snapshots at their source frames.
    /// `entry.sourceFrame` was captured in WINDOW coordinates by the
    /// presenter; converting it via `view.convert(_:from: nil)` only
    /// resolves correctly once `view.window` is non-nil. Called from
    /// `viewDidLayoutSubviews()`, which can fire before the view is attached
    /// to a window (pre-presentation layout) — so this re-syncs the frames
    /// on every pre-entry layout pass instead of computing them once and
    /// locking in a possibly-wrong (zero/garbage) result.
    private func prepareEntrySnapshotsIfNeeded() {
        guard view.window != nil else { return }
        entrySnapshotContainer.isHidden = false
        entrySnapshotContainer.alpha = 1

        if !hasPreparedEntrySnapshots {
            hasPreparedEntrySnapshots = true
            for entry in entrySnapshots.sorted(by: { $0.itemIndex < $1.itemIndex }) {
                let window = EntryMorphWindowView(
                    content: entry.snapshotView,
                    sourceSize: entry.sourceFrame.size,
                    backdrop: items.indices.contains(entry.itemIndex) ? flightBackdrop(for: entry.itemIndex) : nil
                )
                window.layer.cornerRadius = entry.cornerRadius
                window.layer.zPosition = entry.itemIndex == selectedIndex
                    ? 100
                    : CGFloat(50 - abs(entry.itemIndex - selectedIndex))
                entryMorphWindows.append((window, entry.itemIndex, entry.sourceFrame))
                entrySnapshotContainer.addSubview(window)
            }
        }
        for entry in entryMorphWindows {
            entry.window.setWindow(view.convert(entry.sourceFrame, from: nil))
        }
    }

    /// The card's artwork for a flying window, placed as the backdrop plane
    /// places it so the swap to the live carousel shows nothing.
    private func flightBackdrop(for index: Int) -> EntryMorphWindowView.Backdrop {
        let imageView = UIImageView(image: backdropPlane.image(for: index) ?? entryBackdrops[index])
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        if imageView.image == nil {
            // Still loading: fade it in when it lands rather than popping.
            let item = items[index]
            Task { [weak imageView] in
                guard let image = await BackdropPlaneView.backdropImage(for: item), let imageView else { return }
                UIView.transition(with: imageView, duration: 0.3, options: .transitionCrossDissolve) {
                    imageView.image = image
                }
            }
        }
        let card = carouselFrameInView(for: index)
        return EntryMorphWindowView.Backdrop(
            imageView: imageView,
            cardSize: card.size,
            artInCard: CGRect(
                x: (card.width - view.bounds.width) / 2 + layout.parallaxOffset(for: index),
                y: -card.minY,
                width: view.bounds.width,
                height: view.bounds.height))
    }

    private func flightDim(for index: Int) -> CGFloat {
        PreviewCarouselGeometry.neighbourDimAlpha * abs(layout.normalizedPosition(for: index))
    }

    /// Windows for the cards with no tile to fly from or to (the two peeks, and the
    /// centre when its tile had no artwork): they hold the card's frame and only fade.
    private func tilelessPeekWindows(flying: Set<Int>) -> [EntryMorphWindowView] {
        [selectedIndex - 1, selectedIndex, selectedIndex + 1]
            .filter { items.indices.contains($0) && !flying.contains($0) }
            .map { index in
                let card = carouselFrameInView(for: index)
                let window = EntryMorphWindowView(
                    content: UIView(), sourceSize: card.size, backdrop: flightBackdrop(for: index))
                window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
                window.setWindow(card)
                window.dimAlpha = flightDim(for: index)
                entrySnapshotContainer.addSubview(window)
                return window
            }
    }

    /// Backdrops preloaded for the cards the entry flight shows, by index.
    private var entryBackdrops: [Int: UIImage] = [:]
    private var entryBackdropTask: Task<Void, Never>?

    /// Start loading the backdrops of the opening card and its neighbours,
    /// with the same rule the plane uses.
    private func preloadEntryBackdrops() {
        let cards = self.items
        let indices = [selectedIndex, selectedIndex - 1, selectedIndex + 1].filter { cards.indices.contains($0) }
        entryBackdropTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (Int, UIImage?).self) { group in
                for index in indices {
                    group.addTask { (index, await BackdropPlaneView.backdropImage(for: cards[index])) }
                }
                for await (index, image) in group {
                    if let image { self?.entryBackdrops[index] = image }
                }
            }
        }
    }

    /// Wait until the opening card's backdrop is loaded, at most `timeout`.
    private func waitForEntryBackdrop(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while entryBackdropTask != nil, entryBackdrops[selectedIndex] == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func runRowEntryMorph() {
        prepareEntrySnapshotsIfNeeded()

        // Ensure the live carousel is in its final first-frame position behind
        // the source snapshots before it fades in.
        collectionView.layoutIfNeeded()
        collectionView.contentOffset = layout.contentOffsetCentered(index: selectedIndex)
        syncCards()
        backdrop.alpha = 0
        backdropPlane.alpha = 0
        collectionView.alpha = 0
        entrySnapshotContainer.alpha = 1

        let peeks = tilelessPeekWindows(flying: Set(entryMorphWindows.map(\.itemIndex)))
        peeks.forEach { $0.alpha = 0 }

        // One spring moves and fades everything; the live carousel is swapped
        // in under the settled windows at the end.
        let morpher = Self.makeShelfTransitionAnimator()
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            for entry in self.entryMorphWindows {
                guard self.items.indices.contains(entry.itemIndex) else {
                    entry.window.alpha = 0
                    continue
                }
                entry.window.setWindow(self.carouselFrameInView(for: entry.itemIndex))
                entry.window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
                entry.window.tileAlpha = 0
                entry.window.dimAlpha = self.flightDim(for: entry.itemIndex)
            }
            peeks.forEach { $0.alpha = 1 }
            self.backdrop.alpha = 1
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            self.backdropPlane.alpha = 1
            self.collectionView.alpha = 1
            for entry in self.entryMorphWindows {
                entry.window.removeFromSuperview()
            }
            peeks.forEach { $0.removeFromSuperview() }
            self.entryMorphWindows.removeAll()
            self.entrySnapshotContainer.isHidden = true
            // The plane holds the backdrops now; the preloaded copies go.
            self.entryBackdrops.removeAll()
            self.entryBackdropTask = nil
            self.state.completeEntryMorph()
            self.updateCurrentCellChrome(animated: true)
        }
        morpher.startAnimation()
    }

    /// Apple's shelf-tile transition spring (damping ratio 1.22, no overshoot),
    /// shared by entry and exit. UIKit ignores the duration for a physical
    /// spring and runs it for its settling time, about 0.75s.
    private static func makeShelfTransitionAnimator() -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(
            duration: 0,
            timingParameters: UISpringTimingParameters(
                mass: 1, stiffness: 150, damping: 30, initialVelocity: .zero))
    }

    /// Place the artwork panels and set each card's hairline for the current offset.
    private func syncCards() {
        backdropPlane.sync(to: layout, offset: collectionView.contentOffset)
        for case let card as PreviewCardView in collectionView.visibleCells {
            guard let index = collectionView.indexPath(for: card)?.item else { continue }
            card.setHairline(position: layout.normalizedPosition(for: index))
        }
    }

    private func carouselFrameInView(for index: Int) -> CGRect {
        let geom = PreviewCarouselGeometry.self
        let centered = geom.centeredCardFrame(in: view.bounds)
        let stride = centered.width + geom.sideCardGap
        let selectedOffset = stride * CGFloat(selectedIndex)
        return centered.offsetBy(dx: stride * CGFloat(index) - selectedOffset, dy: 0)
    }

    /// Frame the centered cell occupies in the view's coordinate
    /// space. Used by the morph snapshot for its target frame.
    private func centeredFrameInWindow() -> CGRect {
        PreviewCarouselGeometry.centeredCardFrame(in: view.bounds)
    }

    // MARK: - Input handling

    // Must return true so this VC can become first responder and receive
    // pressesBegan. Without this, the collection view has no focusable
    // items (canFocusItemAt returns false) so UIKit never installs this VC
    // in the responder chain — Menu presses route to the presenter instead.
    override var canBecomeFirstResponder: Bool { return true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewCarouselLog.info("[Lifecycle] viewWillDisappear isExpanded=\(self.isExpanded) presentingVC=\(self.presentingViewController != nil)")
        // A detail page opened from this one (a Related or filmography pick)
        // closing: the page under it gets its backdrops back first.
        if isBeingDismissed { (presentingViewController as? CoverablePage)?.coverWillDismiss() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back from a full-screen cover (the player).
        backdropPlane.restoreImages()
    }

    /// An actor page or another detail page covers this one completely:
    /// drop the backdrops while it does. Browsing title → actor → title →
    /// actor stacks these pages, and each held a few screens of pixels.
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        let covers = viewControllerToPresent is PersonDetailViewController
            || viewControllerToPresent is PreviewCarouselViewController
            || viewControllerToPresent is MediaItemDetailPageViewController
        super.present(viewControllerToPresent, animated: flag) { [weak self] in
            if covers { self?.backdropPlane.releaseImages() }
            completion?()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Torn down from outside (deep link, profile switch): no dismiss ran.
        // Covered by a player, the carousel is still presented and stays as is.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController == nil else { return }
            self.teardown()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A presented VC's next responder is its presenter, so a press the
        // Watched prompt or the episode page declines bubbles up to here. It
        // belongs to them, not to the carousel underneath.
        guard presentedViewController == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            switch press.type {
            // .menu is owned by the menu gesture recognizer (see viewDidLoad).
            case .rightArrow:
                // From an episode description, Left/Right jumps to the ADJACENT
                // episode's thumb (the description is a per-episode drill-down,
                // not a horizontal row). The engine can't reach the adjacent
                // thumb on its own (it sits fully above the description), so
                // redirect via a one-shot preferred-focus target.
                if state.phase == .detailsStable, expandedDetail.episodeDescriptionFocused,
                   expandedDetail.armAdjacentEpisodeThumb(forward: true) {
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                    expandedDetail.clearArmedEpisodeFocus()
                    return
                }
                // Only consume Left/Right to page the carousel. In the expanded
                // hero / details the focus engine must get them so the user can
                // move horizontally among season pills, episodes, cast, etc.
                if state.isCarouselInputEnabled { pageForward(); return }
            case .leftArrow:
                if state.phase == .detailsStable, expandedDetail.episodeDescriptionFocused,
                   expandedDetail.armAdjacentEpisodeThumb(forward: false) {
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                    expandedDetail.clearArmedEpisodeFocus()
                    return
                }
                if state.isCarouselInputEnabled { pageBackward(); return }
            case .select, .playPause:
                // Select OR Play/Pause on the centered card expands to
                // the fullscreen detail. Matches SwiftUI's
                // PreviewOverlayHost.swift:183-192 — both Tap and
                // Play/Pause call expandCurrentCard().
                if state.isCarouselInputEnabled {
                    expandCurrentCard()
                    return
                }
            case .downArrow:
                if handleDownNavigation() { return }
            case .upArrow:
                if handleUpNavigation() { return }
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Vertical navigation
    //
    // Shared by .upArrow/.downArrow PRESSES (d-pad / clickpad clicks) and by the
    // up/down SWIPE recognizers (touch surface, e.g. the iPhone remote), which
    // emit no arrow presses. Both call these, so the two input paths cannot
    // drift. Each returns true when it consumed the input; false means "not
    // ours" — the press falls through to the focus engine, and the swipe
    // recognizer refuses to begin so the engine sees the touches instead.

    /// Down: carousel → hero → below-fold details, and pills → episodes.
    @discardableResult
    private func handleDownNavigation() -> Bool {
        // Down from the carousel expands the centered card to the hero —
        // the mirror of Up (hero → carousel). Same action as Select, so
        // Down walks carousel → hero → details.
        if state.isCarouselInputEnabled {
            expandCurrentCard()
            return true
        }
        // Down from the expanded hero hands focus into the real
        // below-fold collection (focus-driven nav + auto-scroll, which
        // drives the hero choreography).
        if state.phase == .expandedHero {
            enterBelowFold()
            return true
        }
        // Down from the season pills drops focus into the episodes — at
        // the SELECTED season's first episode. The orthogonal rail was
        // scrolled there on pill-focus, but the focus engine still
        // remembers episode 0 / season 1; arm the preferred-focus target
        // across this update so it enters the current season instead.
        if state.phase == .detailsStable, expandedDetail.focusIsOnPills {
            expandedDetail.detailsFocusTarget = .episodes
            expandedDetail.armPillEntryFocus()
            setNeedsFocusUpdate(); updateFocusIfNeeded()
            expandedDetail.disarmPillEntryFocus()
            return true
        }
        return false
    }

    /// Up: episodes → pills → hero → carousel.
    @discardableResult
    private func handleUpNavigation() -> Bool {
        // Up choreography ONLY at the top of the details: pills → hero,
        // episodes → pills. From a LOWER section (Trailers/Related/Cast/
        // About/Info) we must NOT intercept — fall through to the focus
        // engine so it moves focus up ONE row. (The previous version
        // forced focus to the pills on every Up, so one Up from any lower
        // row jumped straight to the top.)
        if state.phase == .detailsStable {
            if expandedDetail.focusIsOnPills {
                // Already on the season pills → Up collapses to the hero.
                returnToHeroFromBelowFold()
                return true
            }
            if expandedDetail.focusIsOnEpisodes {
                // The primary row (episodes for shows, trailers/related for
                // movies) is the anchor: Up lands here first. If it JUST
                // took focus on THIS press (the engine moved focus up before
                // pressesBegan ran), stick on it — only a deliberate Up from
                // a RESTING primary row lifts to pills / collapses.
                //  - episodeThumbJustTookFocus: within-section description→thumb
                //    (no section change, so the section gate misses it).
                //  - episodesJustTookFocus: a lower row → primary section
                //    change (covers movies, where there's no episode thumb).
                if expandedDetail.episodeThumbJustTookFocus
                    || expandedDetail.episodesJustTookFocus { return true }
                if expandedDetail.hasSeasonPills {
                    // Episodes → lift to the pills. The pills are
                    // non-focusable while on the episodes, so the engine
                    // can't grab one; setting target=.pills enables them
                    // and drives focus to the SELECTED season's pill.
                    expandedDetail.detailsFocusTarget = .pills
                    setNeedsFocusUpdate(); updateFocusIfNeeded()
                } else {
                    returnToHeroFromBelowFold()   // no pills → straight to hero
                }
                return true
            }
            // Lower section: let the focus engine move up one row.
            return false
        }
        // Up from the expanded hero collapses to the carousel — the
        // mirror of Down (carousel → hero → details). Same path as Menu
        // from the hero, so Up and Back stay identical at every level.
        // In standalone detail the hero IS the top — Up does nothing; only
        // Back/Menu dismisses (there's no carousel to collapse to).
        if state.phase == .expandedHero {
            if standaloneDetail { return true }
            handleMenuPress()
            return true
        }
        return false
    }

    // MARK: - Watch-state refresh (issue #228)

    /// Re-read the centered item's watch state from the server and repaint the
    /// two surfaces that render it: the hero chrome and the episode rail.
    ///
    /// Both are repainted IN PLACE rather than re-seeded. Re-assigning
    /// `items[selectedIndex]` through the normal `item` setters would rebuild
    /// the action row and re-apply the below-fold snapshot, and the Play pill /
    /// an episode card is almost always the focused view when the player
    /// dismisses back onto this surface.
    private func refreshWatchState() {
        // Off-screen (something is presented over us, e.g. the episode detail
        // page) we still refresh — it's one GET, and being right when the user
        // comes back matters more than skipping it. But if the view has never
        // loaded there is nothing to repaint.
        guard isViewLoaded, items.indices.contains(selectedIndex) else { return }
        let index = selectedIndex
        let item = items[index]
        guard !item.isMetadataOnly,
              let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID)
        else { return }

        watchRefreshToken &+= 1
        let token = watchRefreshToken

        // Episode rail first — it owns its own fetch and its own token, and it
        // repaints only the cards whose state actually moved.
        expandedDetail.refreshWatchState()

        // Hero: `fullDetail` is a single uncached metadata GET whose `.item` is
        // a freshly-mapped MediaItem, so it carries the committed watch state.
        Task { [weak self] in
            guard let detail = try? await provider.fullDetail(for: item.ref) else { return }
            await MainActor.run {
                guard let self,
                      self.watchRefreshToken == token,
                      self.items.indices.contains(index),
                      self.items[index].ref == detail.item.ref
                else { return }
                let refreshed = detail.item
                guard refreshed != self.items[index] else { return }
                self.items[index] = refreshed
                self.expandedDetail.updateItemInPlace(refreshed)
                let path = IndexPath(item: index, section: 0)
                (self.collectionView.cellForItem(at: path) as? PreviewCardView)?
                    .refreshWatchState(from: refreshed)
            }
        }
    }

    // MARK: - Playback

    /// Launch playback for a MediaItem (episode thumb Select): resolve the
    /// provider-agnostic MediaItem → a concrete `PlexMetadata` (with full Stream
    /// data for DV/HDR), build the player, and present it over the carousel.
    /// Returns to the detail when the player dismisses. No edit to the off-limits
    /// PlexHomeViewController — the carousel presents the player itself.
    /// Hero Play. For a show, play its on-deck episode (Plex OnDeck); a movie /
    /// episode plays directly.
    /// Present an item's FULL expanded detail standalone (no carousel) — reuses
    /// this same VC in `standaloneDetail` mode. Used for Related drill-ins.
    private func presentStandaloneDetail(_ item: MediaItem) {
        // A collection tile opens the collection page. Arm the shelf row's
        // restore first, while the tile still exists: the carousel cannot
        // resolve focus while the page is up, and on dismissal the engine
        // may resolve before any callback runs. The page's onDismiss re-arms
        // and applies it, so focus returns to the tile with the row unscrolled.
        // No focus request here: focus is still on the tile, so a request
        // would be honoured now and spend the row's one-shot tile index.
        if item.kind == .collection {
            expandedDetail.restoreShelfRowFocusIfNeeded(requestingFocus: false)
            PlexHomeViewController.openCollectionIfNeeded(item, from: self) { [weak self] in
                self?.restoreBelowFoldFocusAfterReturn()
            }
            return
        }
        // The standalone detail is presented .overFullScreen, so THIS controller
        // never disappears and therefore never re-appears — viewDidAppear does
        // not fire on the way back. Restore focus from the dismiss callback,
        // which is the only signal the presenter gets.
        let detail = PreviewCarouselViewController(
            items: [item],
            selectedIndex: 0,
            sourceFrame: .zero,
            sourceTarget: nil,
            standaloneDetail: true,
            onDismiss: { [weak self] _ in self?.restoreBelowFoldFocusAfterReturn() })
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(detail, animated: true)
    }

    /// "Go to Show" from an episode: the SHOW's own detail, so its Watched
    /// button acts on the whole show. `show` skips the fetch when the caller
    /// already has it. From a page this show's detail presented, goes back to
    /// that detail instead of stacking a second one.
    static func openShowDetail(_ showRef: MediaItemRef, show: MediaItem? = nil, from presenter: UIViewController) {
        if let below = presenter.presentingViewController as? PreviewCarouselViewController,
           below.items.indices.contains(below.selectedIndex),
           below.items[below.selectedIndex].ref == showRef {
            presenter.dismiss(animated: true)
            return
        }
        Task { @MainActor [weak presenter] in
            var resolved = show
            if resolved == nil, let provider = MediaProviderRegistry.shared.provider(for: showRef.providerID) {
                resolved = try? await provider.fullDetail(for: showRef).item
            }
            guard var top = presenter, let resolved else { return }
            while let presented = top.presentedViewController { top = presented }
            top.present(PreviewCarouselViewController(
                items: [resolved], selectedIndex: 0, sourceFrame: .zero, sourceTarget: nil,
                standaloneDetail: true, onDismiss: { _ in }), animated: true)
        }
    }

    /// Put focus back where it was in the below-fold after returning from a
    /// standalone detail (Related / cast filmography).
    ///
    /// Called from the presented VC's dismiss callback because `.overFullScreen`
    /// means this controller's appearance methods never fire for that round trip.
    func restoreBelowFoldFocusAfterReturn() {
        guard state.phase == .detailsStable else { return }
        expandedDetail.restoreShelfRowFocusIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        expandedDetail.clearArmedShelfRestore()
    }

    /// Person filmography poster Select → open the item's full expanded detail.
    /// Server-backed and metadata-only items both go through `presentStandaloneDetail`:
    /// the carousel handles `isMetadataOnly` items already (Watchlist-primary chrome),
    /// so a single path covers both cases.
    private func presentPersonFilmographyItem(_ item: MediaItem) {
        presentStandaloneDetail(item)
    }

    /// Info button → structured info popup (scrollable), styled like our other
    /// popups but with Information / Languages / Accessibility sections.
    private func presentInfoPopup(_ detail: MediaItemDetail) {
        let content = InfoPopupContent.fullInfo(detail: detail)
        // Force the card size (skip the scroll-content measurement, which
        // under-reports and left the card small) — same fix as the Settings
        // Licenses popup.
        let popup = InfoPopupViewController(content: content, width: 900, height: 900, scrollable: true)
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(popup, animated: true)
    }

    /// Play on a show or a season has to resolve to an actual episode — neither
    /// has playable media of its own, and handing Plex a season ratingKey makes
    /// the transcode start hang until it times out.
    private func playHeroItem(_ item: MediaItem) {
        guard item.kind == .show || item.kind == .season else { playMediaItem(item); return }
        Task { [weak self] in
            guard let self,
                  let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID)
            else { return }
            let target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider)
            await MainActor.run { self.playMediaItem(target ?? item) }
        }
    }

    /// The detail page's Play pill, episode-list thumbnails, the Versions
    /// picker and (via `playHeroItem`) the season Play button all land here —
    /// this file's one play entry point, so it's the one place that needed
    /// `ResumePrompt` added (`PlexHomeViewController`'s tile taps/hero/CW
    /// already had an equivalent). `fromBeginning` has no explicit-bypass
    /// caller in this file today (no "Watch from Beginning" action exists on
    /// these surfaces), so every call goes through the decision.
    private func playMediaItem(_ item: MediaItem, fromBeginning: Bool = false, sourceID: String? = nil) {
        guard !fromBeginning else {
            playMediaItemResolved(item, fromBeginning: true, sourceID: sourceID)
            return
        }
        ResumePrompt.resolve(offsetSeconds: item.userState.viewOffset, from: self) { [weak self] startOver in
            self?.playMediaItemResolved(item, fromBeginning: startOver, sourceID: sourceID)
        }
    }

    private func playMediaItemResolved(_ item: MediaItem, fromBeginning: Bool, sourceID: String? = nil) {
        // presentPlayer resolves a Plex ratingKey; any other item plays through
        // its own provider.
        if !item.ref.isPlex {
            ProviderPlayer.play(item, fromBeginning: fromBeginning, sourceID: sourceID, from: self, onDismiss: nil)
            return
        }
        // A nil resumeOffset below means "ask the server", NOT "start at
        // zero" (see `presentPlayer`'s own doc comment) — so "start over"
        // needs an explicit 0, never nil.
        let offsetSec = item.userState.viewOffset
        let resumeOffset: Double? = fromBeginning ? 0 : (offsetSec > 0 ? offsetSec : nil)
        presentPlayer(ratingKey: item.ref.itemID, resumeOffset: resumeOffset, mediaID: sourceID)
    }

    /// Resolve a Plex ratingKey → metadata → present the player. Used for the
    /// hero/episode play AND trailer/extra playback.
    ///
    /// A nil `resumeOffset` means "ask the server", not "start from zero": the
    /// metadata we fetch here is the only place a library-addressable extra's
    /// resume point appears (issue #303 — extras always restarted), and it is
    /// also fresher than a MediaItem's cached userState.
    private func presentPlayer(ratingKey: String, resumeOffset: Double?, mediaID: String? = nil) {
        Task { [weak self] in
            guard let serverURL = PlexAuthManager.shared.selectedServerURL,
                  let token = PlexAuthManager.shared.selectedServerToken else {
                previewCarouselLog.error("[PCV] play handoff: no server/token")
                return
            }
            let network = PlexNetworkManager.shared
            let playItem: PlexMetadata
            do {
                playItem = try await network.getFullMetadata(
                    serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            } catch {
                do {
                    playItem = try await network.getMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                } catch {
                    previewCarouselLog.error("[PCV] play handoff fetch failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            // `viewOffset` is ms. Gated on the shared policy rather than
            // `> 0` so a few accidental seconds don't become a resume point
            // and a nearly-finished extra restarts instead of resuming at
            // the credits.
            let serverResume = playItem.isInProgress
                ? playItem.viewOffset.map { Double($0) / 1000 }
                : nil
            await MainActor.run {
                self?.present(playItem: playItem, serverURL: serverURL, token: token,
                              resumeOffset: resumeOffset ?? serverResume, mediaID: mediaID)
            }
        }
    }

    /// Play a trailer/extra. Extras come in two flavors and only one of them is
    /// addressable as a library item:
    ///
    /// - **User-added** (disc rips): real library ratingKey. `/library/metadata/{key}`
    ///   resolves, so these take the normal metadata-fetch path.
    /// - **Plex IVA** (studio-supplied): NO library ratingKey. The only handle is
    ///   `key`, an absolute part path (`/services/iva/assets/...`). Feeding that to
    ///   `/library/metadata/{id}` builds a nonsense URL that 404s — the cause of
    ///   issue #255, where trailers failed "more times than not" because IVA extras
    ///   are the common case on most libraries.
    ///
    /// For the IVA case the part path is already directly playable, so we skip the
    /// metadata round-trip entirely and hand ContentRouter a synthetic PlexMetadata
    /// whose Part.key IS that path. buildDirectPlayURL then appends the token and
    /// the aether route plays it.
    private func presentExtraPlayer(_ trailer: BelowFoldTrailer) {
        let key = trailer.playbackKey ?? trailer.id
        let route = ExtraPlaybackKey.route(for: key)

        // Which flavor we took. PlexNetworkManager.request() already captures any
        // resulting HTTP/transport/decode failure, but its endpoint tag normalizes
        // on NUMERIC path segments — an IVA path has none, so those failures never
        // grouped under /library/metadata/{id} and this bug stayed invisible in
        // Sentry despite firing constantly. This breadcrumb is the missing context
        // on that capture, not a second report of it.
        let crumb = Breadcrumb(level: .info, category: "playback.extra")
        crumb.message = "Playing extra"
        crumb.data = [
            "route": route.telemetryName,
            "subtype": trailer.subtype.displayName,
            "key_shape": ExtraPlaybackKey.keyShape(key),
            "had_playback_key": trailer.playbackKey != nil
        ]
        SentryBridge.addBreadcrumb(crumb)

        switch route {
        case .libraryMetadata(let ratingKey):
            // nil = resume from whatever the server has for this extra.
            presentPlayer(ratingKey: ratingKey, resumeOffset: nil)

        case .directPartPath(let path):
            // IVA extras aren't library items, so /:/timeline never recorded a
            // position for them — there is nothing to resume from.
            guard let serverURL = PlexAuthManager.shared.selectedServerURL,
                  let token = PlexAuthManager.shared.selectedServerToken else {
                previewCarouselLog.error("[PCV] extra play: no server/token")
                return
            }
            previewCarouselLog.info("[PCV] extra play: direct part path (non-library extra)")
            present(
                playItem: Self.syntheticMetadata(forPartKey: path, trailer: trailer),
                serverURL: serverURL,
                token: token,
                resumeOffset: nil
            )
        }
    }

    /// Minimal PlexMetadata standing in for a non-library extra, carrying the
    /// part path ContentRouter needs to build a direct-play URL.
    private static func syntheticMetadata(forPartKey key: String, trailer: BelowFoldTrailer) -> PlexMetadata {
        let part = PlexPart(id: 0, key: key, duration: nil, file: nil, size: nil, container: nil, Stream: nil)
        let media = PlexMedia(
            id: 0, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
            audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: nil,
            container: nil, videoFrameRate: nil, Part: [part]
        )
        return PlexMetadata(
            ratingKey: trailer.id,
            key: key,
            type: "clip",
            title: trailer.title,
            Media: [media]
        )
    }

    private func present(playItem: PlexMetadata, serverURL: String, token: String, resumeOffset: Double?,
                         mediaID: String? = nil) {
        let viewModel = UniversalPlayerViewModel(
            metadata: playItem,
            serverURL: serverURL,
            authToken: token,
            startOffset: resumeOffset,
            preferredMediaID: mediaID
        )
        // Presents from the topmost VC so Play works both directly on the
        // carousel AND from the episode detail page presented over it.
        PlayerPresenter.present(viewModel: viewModel, from: self)
    }

    // NOTE: Menu is owned SOLELY by the .menu UITapGestureRecognizer
    // installed in viewDidLoad (see UIKIT_FOUNDATIONS §2 + Apple Forums
    // thread 42630 / openradar 25428691). We deliberately do NOT also
    // intercept .menu in pressesEnded/pressesCancelled: doing both makes the
    // responder-chain absorb race the recognizer, the recognizer never
    // recognizes, the press arrives cancelled, and the presentation
    // controller dismisses the modal anyway. With the recognizer as the
    // single owner, it claims the press (preventing the system dismiss) and
    // its action drives collapse-vs-dismiss. No pressesEnded/Cancelled
    // overrides needed.

    // MARK: - Paging

    /// Swiping the finger LEFT drags the strip leftward, revealing the NEXT
    /// card — same direction convention as a right-arrow press.
    @objc private func handleCarouselSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard state.isCarouselInputEnabled else { return }
        switch gesture.direction {
        case .left:  pageForward()
        case .right: pageBackward()
        default:     break
        }
    }

    /// Touch-surface equivalent of an .upArrow / .downArrow press. Only ever
    /// begins for transitions `verticalSwipeWouldNavigate` vouched for, so it
    /// can drive the same choreography the presses do.
    @objc private func handleVerticalSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .down: handleDownNavigation()
        case .up:   handleUpNavigation()
        default:    break
        }
    }

    /// Whether a vertical swipe in the CURRENT state is a hand-off the focus
    /// engine cannot make by itself, and so should be claimed by the recognizer.
    ///
    /// This must stay conservative. In `.detailsStable` the below-fold rows are
    /// focusable and the engine moves between them on its own; claiming the
    /// gesture there would cancel that and break scrolling through the details.
    /// So we claim only the boundary transitions:
    ///   - down: carousel → hero, hero → below-fold, pills → episodes
    ///   - up:   episodes → pills, pills → hero, hero → carousel
    /// Everything else (a lower details row moving one row at a time) is left to
    /// the engine, which mirrors what the arrow-press handlers already do by
    /// falling through to `super.pressesBegan`.
    private func verticalSwipeWouldNavigate(_ direction: UISwipeGestureRecognizer.Direction) -> Bool {
        switch direction {
        case .down:
            if state.isCarouselInputEnabled { return true }
            if state.phase == .expandedHero { return true }
            if state.phase == .detailsStable, expandedDetail.focusIsOnPills { return true }
            return false
        case .up:
            if state.phase == .expandedHero { return true }
            if state.phase == .detailsStable {
                return touchBeganOnDetailsTopRow
                    && (expandedDetail.focusIsOnPills || expandedDetail.focusIsOnEpisodes)
            }
            return false
        default:
            return false
        }
    }

    private func pageForward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimation == nil else { return }
        guard selectedIndex < items.count - 1 else { return }
        animatePage(toIndex: selectedIndex + 1)
    }

    private func pageBackward() {
        guard state.isCarouselInputEnabled else { return }
        guard pagingAnimation == nil else { return }
        guard selectedIndex > 0 else { return }
        animatePage(toIndex: selectedIndex - 1)
    }

    /// Drive `contentOffset` toward the new index across the SwiftUI
    /// baseline cubic curve over 0.78s. Uses CADisplayLink + manual
    /// cubic-Bezier evaluation so layout invalidation happens every
    /// frame — required for parallax tracking and off-screen cell
    /// pre-allocation. `UIViewPropertyAnimator` interpolating
    /// contentOffset does not trigger per-frame layout passes.
    private func animatePage(toIndex newIndex: Int) {
        state.beginPaging()
        // Release the expand offset-pin so paging can move the carousel.
        collectionView.pinnedOffsetX = nil

        // Pre-warm the image for the new far-edge cell so the display
        // link's per-frame layout pass doesn't have to wait on an
        // async fetch when the cell scrolls into view. Without this,
        // the animation pauses ~halfway through while the dequeued
        // cell loads its artwork.
        let direction = newIndex > selectedIndex ? 1 : -1
        let prefetchIndex = newIndex + direction * 2
        if items.indices.contains(prefetchIndex) {
            let item = items[prefetchIndex]
            if let url = item.artwork.backdrop ?? item.artwork.poster {
                Task { _ = await ImageCacheManager.shared.image(for: url) }
            }
        }

        let start = collectionView.contentOffset.x
        let end = layout.contentOffsetCentered(index: newIndex).x
        pagingAnimation = PagingAnimation(
            startOffset: start,
            endOffset: end,
            startTime: CACurrentMediaTime(),
            duration: 0.78,
            targetIndex: newIndex
        )

        let link = CADisplayLink(target: self, selector: #selector(tickPagingAnimation))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickPagingAnimation(_ link: CADisplayLink) {
        guard let anim = pagingAnimation else {
            link.invalidate()
            displayLink = nil
            return
        }

        let elapsed = CACurrentMediaTime() - anim.startTime
        let t = min(1.0, max(0.0, elapsed / anim.duration))
        // SwiftUI baseline cubic curve: control points (0.40, 0.02)
        // and (0.18, 1.0).
        let eased = cubicBezier(t: CGFloat(t), p1x: 0.40, p1y: 0.02, p2x: 0.18, p2y: 1.0)
        let x = anim.startOffset + (anim.endOffset - anim.startOffset) * eased
        // setContentOffset with animated: false issues a non-animated
        // scroll. UICollectionView responds by invalidating layout
        // (because shouldInvalidateLayout(forBoundsChange:) returns
        // true), which recomputes parallax + alpha for every visible
        // cell and queries layoutAttributesForElements with the new
        // viewport.
        collectionView.setContentOffset(CGPoint(x: x, y: 0), animated: false)
        syncCards()

        // The outgoing card's chrome and the below-fold peek fade against its
        // travel, gone well before the card leaves.
        let outgoingCell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        let fade = max(0, 1 - abs(layout.normalizedPosition(for: selectedIndex)) / PreviewCarouselGeometry.contentFadeDistance)
        outgoingCell?.setPagingFade(fade)
        expandedDetail.alpha = fade

        if t >= 1.0 {
            link.invalidate()
            displayLink = nil
            // Hand the fade back: both are at 0 by now, and the new centre
            // fades in from updateCurrentCellChrome.
            outgoingCell?.setIsCurrent(false, animated: false)
            outgoingCell?.setPagingFade(1)
            expandedDetail.setCurrent(false, animated: false)
            expandedDetail.alpha = 1
            selectedIndex = anim.targetIndex
            dismissSourceTarget = makeSourceTarget(for: selectedIndex)
            pagingAnimation = nil
            state.finishPaging()
            // Cascade chrome on the new center cell.
            updateCurrentCellChrome(animated: true)
        }
    }

    /// Evaluate a 1-D cubic Bezier ease for x → y given control
    /// points (p1x, p1y) and (p2x, p2y) (with endpoints fixed at
    /// (0,0) and (1,1)).
    ///
    /// We solve for parameter `u` such that the x-coordinate of the
    /// cubic equals `t`, then return the y-coordinate at that u.
    /// Newton-Raphson + bisection fallback (10 iterations is plenty
    /// for animation precision).
    private func cubicBezier(t: CGFloat, p1x: CGFloat, p1y: CGFloat, p2x: CGFloat, p2y: CGFloat) -> CGFloat {
        // Coefficients for x(u) = ((1-u)^3 * 0) + 3 * (1-u)^2 * u * p1x + 3 * (1-u) * u^2 * p2x + u^3 * 1
        //        = (3 p1x - 3 p2x + 1) u^3 + (-6 p1x + 3 p2x) u^2 + (3 p1x) u
        let cx = 3 * p1x
        let bx = 3 * (p2x - p1x) - cx
        let ax = 1 - cx - bx

        let cy = 3 * p1y
        let by = 3 * (p2y - p1y) - cy
        let ay = 1 - cy - by

        // Find u such that x(u) == t. Newton-Raphson.
        var u = t
        for _ in 0..<10 {
            let x = ((ax * u + bx) * u + cx) * u
            let dx = (3 * ax * u + 2 * bx) * u + cx
            if abs(dx) < 1e-6 { break }
            let nextU = u - (x - t) / dx
            u = max(0, min(1, nextU))
        }

        return ((ay * u + by) * u + cy) * u
    }

    // MARK: - Menu + dismiss

    @objc private func menuGestureFired() {
        handleMenuPress()
    }

    private func handleMenuPress() {
        previewCarouselLog.info("[Menu] phase=\(String(describing: self.state.phase), privacy: .public) isExpanded=\(self.isExpanded)")
        // Menu/Back goes up ONE level. From the scrolled-in details that's the
        // expanded hero (NOT all the way to the carousel) — identical to Up from
        // the season pills, so the two controls behave the same.
        if state.phase == .detailsStable {
            returnToHeroFromBelowFold()
            return
        }
        // The entry flight is not interruptible.
        if state.phase == .entryMorph { return }
        let action = state.exitAction(standaloneDetail: standaloneDetail)
        previewCarouselLog.info("[Menu] action=\(String(describing: action), privacy: .public)")
        switch action {
        case .dismissOverlay:
            // Standalone detail has no carousel behind it — blur-fade dismiss
            // (the transitioningDelegate handles it) back to the previous detail.
            if standaloneDetail { dismiss(animated: true) }
            else { performDismissMorph() }
        case .collapseToCarousel:
            // Phase already transitioned to `.carouselStable` inside
            // `state.exitAction()`. Tear down the child VC. Iter C
            // adds the animated collapse cascade (frame shrink +
            // chrome cross-fade); Iter B is an instant teardown.
            collapseExpandedCard()
        }
    }

    // MARK: - Expand / Collapse

    /// Expand the centered card to fullscreen. State machine
    /// transitions through `.expandingHero` → `.expandedHero`. The
    /// custom layout reshapes the centered cell's frame to the
    /// collection view's full bounds; the cell's chromeView mutates
    /// its constraint constants; the panel's corner radius lerps to 0.
    /// All happen on the morph controller's one ease-in-out animator
    /// (`PreviewCarouselGeometry.expandAnimationDuration`).
    ///
    /// Critical: the cell view and the chrome view are the SAME
    /// instances throughout — no second view tree, no reparenting,
    /// no re-render. The animation is a constraint+frame tween on
    /// existing views. This is what gives true visual continuity
    /// matching SwiftUI's persistent-view-tree model.
    ///
    private func expandCurrentCard() {
        guard !isExpanded else { return }
        // A page in flight still owns selectedIndex and the outgoing card's chrome.
        guard pagingAnimation == nil else { return }
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]

        previewCarouselLog.info("[Expand] BEGIN idx=\(self.selectedIndex) ref=\(item.ref.itemID, privacy: .public)")

        state.beginExpand()
        isExpanded = true

        // Single-animator morph (CarouselMorphController): the cell window
        // (layout swap to PreviewExpandedLayout), the backdrop panel
        // container grow to fullscreen, the chrome insets, and the
        // corner-radius lerp to 0 ALL run on one UIViewPropertyAnimator
        // curve. Nothing can drift. See
        // docs/superpowers/specs/2026-05-31-two-layout-carousel-morph-design.md.
        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        // Complete the chrome cascade NOW so the metadata is fully present when
        // the morph starts. Entry items settle before you expand them; a
        // paged-to item expanded mid-cascade would have its metadata still
        // fading in while the backdrop just grows — the "metadata not aligning
        // with the background" artifact on non-first items. Snapping cancels the
        // in-flight fade and pins alpha 1 so only position morphs.
        cell?.setIsCurrent(true, animated: false)
        expandedDetail.setCurrent(true, animated: false)
        // Pin the carousel offset to the centered position for the WHOLE morph +
        // expanded state. The layout swap's deferred contentOffset zeroing would
        // otherwise throw the expanded cell (placed at content x = offset) off
        // the right edge for non-first items. Cleared on collapse.
        collectionView.pinnedOffsetX = collectionView.contentOffset.x
        morphController.expand(centeredIndex: selectedIndex, in: view.bounds, cell: cell) { [weak self] in
            guard let self else { return }
            self.state.finishExpand()
            // Reveal the real focus-driven below-fold (post-morph, §6).
            self.expandedDetail.revealBelowFoldCollection()
            self.setNeedsFocusUpdate()
        }
    }

    /// Down from the expanded hero: hand focus into the real below-fold
    /// collection. The focus engine moves to the first cell + auto-scrolls,
    /// which fires the collection's scroll → drives the hero choreography.
    private func enterBelowFold() {
        guard state.phase == .expandedHero else { return }
        state.markDetailsStable()
        // Always enter the details on the episodes (not stale on the pills from a
        // previous pills→hero→Down round-trip).
        expandedDetail.detailsFocusTarget = .episodes
        // The below-fold's scroll now drives the hero fade.
        expandedDetail.setBelowFoldScrollActive(true)
        // Slide the episodes up (timed) WITHOUT making the collection focusable
        // yet — otherwise the focus engine scrolls to its focused cell and
        // fights the slide (over-scrolling past the episodes, all the way to
        // Cast). The blur + metadata fade + logo ride this single movement.
        // Hand focus in only once the slide settles.
        expandedDetail.belowFoldCollection.slideToDetailsTop(animated: true) { [weak self] in
            guard let self else { return }
            self.expandedDetail.setBelowFoldInteractive(true)
            // Flush layout BEFORE asking for focus. The preferred-focus target
            // may be a deep episode in the orthogonal rail, and UIKit rejects a
            // preferred index path whose cell isn't realized yet (it throws
            // NSInternalInconsistencyException from _delegatePreferredIndexPath).
            // The rail positions itself in layoutSubviews, so run that first.
            self.expandedDetail.belowFoldCollection.layoutIfNeeded()
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            // Focus is now in the below-fold; make the faded chrome buttons
            // non-focusable so Up from the primary row can't escape into them
            // (which reads as "jumps back to the carousel").
            (self.collectionView.cellForItem(at: IndexPath(item: self.selectedIndex, section: 0)) as? PreviewCardView)?
                .setChromeActionRowFocusable(false)
        }
    }

    /// Up from the top of the below-fold: return focus to the hero, reset the
    /// collection to its peek position (→ scrollProgress 0, hero un-fades).
    private func returnToHeroFromBelowFold() {
        guard state.phase == .detailsStable else { return }
        state.returnToExpandedHero()
        // Re-enable the chrome buttons (disabled on enterBelowFold) BEFORE the
        // focus update, so focus can park back on the hero Play button.
        (collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView)?
            .setChromeActionRowFocusable(true)
        // Exact reverse of enterBelowFold: keep the below-fold scroll coupling LIVE
        // so the collection's slide back to the peek rest drives the hero fade-in
        // (blur out, chrome in, logo out, pills out) through the same single
        // chain — scrollViewDidScroll -> driveScrollProgress -> applyHeroProgress.
        // Make it non-focusable so focus parks on the hero anchor; the coupling is
        // torn down only once the slide completes.
        expandedDetail.setBelowFoldInteractive(false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        expandedDetail.belowFoldCollection.slideToHeroRest(animated: true) { [weak self] in
            guard let self else { return }
            self.expandedDetail.setBelowFoldScrollActive(false)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    // MARK: - Hero layer choreography (backdrop blur + metadata fade)

    /// Drive the VC-owned hero layers from below-fold scroll progress (0→1):
    /// blur the backdrop in and fade the hero metadata (cell chrome) out.
    private func driveHeroLayers(_ progress: CGFloat) {
        let p = max(0, min(1, progress))
        blurOverlay.isHidden = p <= 0.01
        blurAnimatorIfNeeded().fractionComplete = min(0.999, max(0.001, p))

        // Metadata fades out faster than the blur fades in (gone by ~p=0.6).
        // Carousel metadata fades out FAST + early (gone by ~p=0.4) so it
        // clears before the top logo fades in (which starts later) — no overlap.
        let chromeAlpha = 1 - min(1, p * 2.6)
        (collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView)?
            .setHeroChromeAlpha(chromeAlpha)
    }

    /// Lazily build the paused blur animator. `fractionComplete` is the blur
    /// intensity (Apple's way to scrub a UIVisualEffectView — not alpha).
    private func blurAnimatorIfNeeded() -> UIViewPropertyAnimator {
        if let a = blurAnimator { return a }
        let a = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
            // Pinned dark like Apple's detail backdrop: `.regular` follows
            // the system appearance and turns into a white frost under Light.
            self?.blurOverlay.effect = UIBlurEffect(style: .dark)
        }
        a.pausesOnCompletion = true
        a.startAnimation()
        a.pauseAnimation()
        blurAnimator = a
        return a
    }

    /// Reverse of `expandCurrentCard`. Returns the centered cell to
    /// its carousel slot, restores chrome insets, restores corner
    /// radius, all on the same ease-in-out curve.
    private func collapseExpandedCard() {
        guard isExpanded else { return }
        previewCarouselLog.info("[Collapse] BEGIN idx=\(self.selectedIndex)")

        isExpanded = false

        // Tear down the real below-fold collection (restore the placeholder
        // peek) before the collapse morph, and return the peek scroll to rest.
        expandedDetail.hideBelowFoldCollection()
        expandedDetail.reset()

        let cell = collectionView.cellForItem(at: IndexPath(item: selectedIndex, section: 0)) as? PreviewCardView
        morphController.collapse(centeredIndex: selectedIndex, cell: cell) { [weak self] in
            guard let self else { return }
            // Restore carousel-mode backdrop panels after collapse.
            self.syncCards()
            // Focus update AFTER the morph so a focus-driven animation never
            // runs concurrently with the morph curve.
            self.setNeedsFocusUpdate()
        }
    }

    /// Dismiss the overlay. If we entered via row snapshots, reverse that
    /// exact morph (`runRowExitMorph`) so exit mirrors entry. Otherwise the
    /// artwork lives in the VC-owned `backdropPlane` (not in the cell), so
    /// the old "fly a chrome-only PreviewCardView snapshot back to the
    /// source tile" reverse-entry morph desynced: the chrome snapshot flew
    /// off while the artwork plane sat orphaned ("metadata dismisses first,
    /// then the carousel"). In that case we fade ALL overlay layers
    /// together — backdrop plane (artwork), the collection view (chrome),
    /// and the black backdrop — on ONE animator, so everything leaves in
    /// lockstep.
    private func performDismissMorph() {
        guard state.phase != .exiting else { return }
        // The exit flight starts from settled geometry: not mid-page, not mid-collapse.
        guard pagingAnimation == nil, !morphController.isAnimating else { return }
        state.beginExit()
        onPrepareDismiss(dismissSourceTarget)
        // Fly only when the centred card has a tile on screen to land on.
        if !entrySnapshots.isEmpty {
            let tiles = freshEntrySnapshots?(dismissSourceTarget) ?? []
            if tiles.contains(where: { $0.itemIndex == selectedIndex }) {
                runRowExitMorph(to: tiles)
                return
            }
        }
        teardown()
        // Rivulet's own fade (Apple always has a tile to return to), so it
        // keeps its timing instead of following the expand morph.
        let animator = UIViewPropertyAnimator(duration: 0.35, curve: .easeInOut)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.backdropPlane.alpha = 0
            self.collectionView.alpha = 0
            self.backdrop.alpha = 0
            self.expandedDetail.alpha = 0
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: false) {
                self.onDismiss(self.dismissSourceTarget)
            }
        }
        animator.startAnimation()
    }

    /// Reverse of `runRowEntryMorph()`: each card flies to its tile's current
    /// frame as a window of its artwork, the tile fading in above it. The
    /// chrome is gone from the first frame; everything rides one spring.
    private func runRowExitMorph(to tiles: [PreviewEntrySnapshot]) {
        entrySnapshotContainer.isHidden = false
        entrySnapshotContainer.alpha = 1

        var windows: [(window: EntryMorphWindowView, tile: PreviewEntrySnapshot)] = []
        for tile in tiles where items.indices.contains(tile.itemIndex) {
            let window = EntryMorphWindowView(
                content: tile.snapshotView,
                sourceSize: tile.sourceFrame.size,
                backdrop: flightBackdrop(for: tile.itemIndex))
            window.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
            window.layer.zPosition = tile.itemIndex == selectedIndex
                ? 100
                : CGFloat(50 - abs(tile.itemIndex - selectedIndex))
            window.setWindow(carouselFrameInView(for: tile.itemIndex))
            window.tileAlpha = 0
            window.dimAlpha = flightDim(for: tile.itemIndex)
            entrySnapshotContainer.addSubview(window)
            windows.append((window, tile))
        }
        let peeks = tilelessPeekWindows(flying: Set(windows.map(\.tile.itemIndex)))

        backdropPlane.alpha = 0
        collectionView.alpha = 0
        expandedDetail.alpha = 0

        let morpher = Self.makeShelfTransitionAnimator()
        morpher.addAnimations { [weak self] in
            guard let self else { return }
            for (window, tile) in windows {
                window.setWindow(self.view.convert(tile.sourceFrame, from: nil))
                window.layer.cornerRadius = tile.cornerRadius
                window.tileAlpha = 1
                window.dimAlpha = 0
            }
            peeks.forEach { $0.alpha = 0 }
            self.backdrop.alpha = 0
        }
        morpher.addCompletion { [weak self] _ in
            guard let self else { return }
            // The real tiles take over from the snapshots resting on them.
            self.teardown()
            self.dismiss(animated: false) {
                self.onDismiss(self.dismissSourceTarget)
            }
        }
        morpher.startAnimation()
    }

    private func makeSourceTarget(for index: Int) -> PreviewSourceTarget? {
        guard let existing = dismissSourceTarget,
              items.indices.contains(index) else { return dismissSourceTarget }
        if let sourceItemIDs, sourceItemIDs.indices.contains(index) {
            return PreviewSourceTarget(rowID: existing.rowID, itemID: sourceItemIDs[index])
        }
        let item = items[index]
        return PreviewSourceTarget(rowID: existing.rowID, itemID: item.ref.itemID)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PreviewCarouselViewController: UIGestureRecognizerDelegate {

    /// Gate the swipes. On tvOS the focus engine reads the same
    /// indirect-touch stream a recognizer does, and a recognizer that reaches
    /// .began CANCELS the competing focus interaction. So a swipe may only be
    /// claimed where the engine has nothing useful to do with it. Vertical:
    /// the hand-off transitions in `verticalSwipeWouldNavigate` — anywhere
    /// else (moving between the below-fold rows) decline and let the engine
    /// have the touches. Horizontal: only while the carousel owns input — in
    /// the expanded/detail states the chrome action buttons ARE focusable and
    /// the engine needs the swipe to move focus between them. Declining must
    /// happen here; bailing inside the handler is too late, the begun
    /// recognizer has already stolen the gesture.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === verticalSwipeRecognizers.first {
            touchBeganOnDetailsTopRow = state.phase == .detailsStable
                && (expandedDetail.focusIsOnPills || expandedDetail.focusIsOnEpisodes)
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return true }
        // Touch twin of the pressesBegan guard: nothing pages or scrolls under a prompt.
        guard presentedViewController == nil else { return false }
        if verticalSwipeRecognizers.contains(where: { $0 === swipe }) {
            return verticalSwipeWouldNavigate(swipe.direction)
        }
        return state.isCarouselInputEnabled
    }
}

// MARK: - UICollectionViewDataSource / Delegate

extension PreviewCarouselViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PreviewCardView.reuseIdentifier,
            for: indexPath
        ) as! PreviewCardView
        if items.indices.contains(indexPath.item) {
            cell.item = items[indexPath.item]
        }
        cell.onPlay = { [weak self] item in self?.playHeroItem(item) }
        cell.onPlayVersion = { [weak self] item, sourceID in self?.playMediaItem(item, sourceID: sourceID) }
        cell.onShowInfo = { [weak self] detail in self?.presentInfoPopup(detail) }
        let cardIndex = indexPath.item
        cell.onCopyArtwork = { [weak self] artwork in self?.backdropPlane.setArtwork(artwork, for: cardIndex) }
        // Default to non-current; if this dequeued cell happens to be
        // at selectedIndex (e.g. on first viewport population), the
        // entry-morph completion or paging completion will flip it via
        // updateCurrentCellChrome.
        cell.setIsCurrent(indexPath.item == selectedIndex && hasRunEntryMorph,
                          animated: false)
        cell.setHairline(position: layout.normalizedPosition(for: indexPath.item))
        return cell
    }

    // Block the focus engine from auto-scrolling the collection view
    // — we drive scroll ourselves via animatePage so we can use the
    // exact cubic timing curve.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        // NEVER. A focusable cell is a LEAF focus item: the engine focuses the
        // cell and reaches its action row only through the cell's own
        // `preferredFocusEnvironments` redirect, which a DIRECTIONAL search does
        // not consult. So making the expanded cell focusable landed focus on
        // Play and then killed Left/Right between the buttons on every remote —
        // presses and swipes alike, because both are the same focus move.
        // A NON-focusable cell is a pass-through container and the engine finds
        // the buttons directly; the redirect still works for the driven landing.
        // House pattern: ShelfRowCell and HeroOverlayCell both host focusable
        // content and both return false.
        //
        // Focuslessness elsewhere is unaffected: the chrome is
        // `isUserInteractionEnabled = false` in .carouselStable, and
        // `enterBelowFold` turns the action row off so Up from the episodes
        // can't climb back into the hero.
        return false
    }
}

/// Invisible, always-focusable anchor. Exists solely to give the tvOS focus
/// engine a target inside the focusless preview modal so Menu presses are
/// delivered into the VC's responder chain (presses go to the FOCUSED view
/// on tvOS, then climb the chain). It has zero size and draws nothing, so it
/// never shows and never competes with visible content for focus.
final class PreviewFocusAnchorView: UIView {
    override var canBecomeFocused: Bool { true }
}

// MARK: - Covered by another page

/// A page that lets go of its heavy images while another full-screen page
/// covers it, told when that cover is about to close.
@MainActor
protocol CoverablePage: AnyObject {
    func coverWillDismiss()
}

extension PreviewCarouselViewController: CoverablePage {
    func coverWillDismiss() { backdropPlane.restoreImages() }
}

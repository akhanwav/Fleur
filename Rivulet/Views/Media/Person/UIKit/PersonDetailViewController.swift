// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonDetailViewController.swift
//  Rivulet
//
//  The person (cast/crew) detail page — Docs/atv_ref/actor_details_ref.JPG.
//  A dark blue→black gradient page with a biography header (circular portrait +
//  name + truncated bio + MORE) over the person's filmography: the Watchlist's
//  filter header (Sort / Type / Genre, plus an On My Servers toggle) and a
//  poster grid with each title's year and the person's character under it.
//  Owned and unowned titles open the same page.
//
//  Structure mirrors PlexHomeViewController's Watchlist grid: a
//  UICollectionViewCompositionalLayout with a header section, the filter
//  header (`WatchlistFilterHeaderControl`) and a six-across grid of
//  `WatchlistPosterCell`s.
//
//  The vertical axis is owned by `FocusScrollControlledCollectionView`
//  (isScrollEnabled = false; it self-drives the vertical scroll from
//  didUpdateFocus), the same component the MediaDetail page adopts. With
//  topSectionIndex left nil, every focused row simply centers.
//
//  Data comes from `PersonFilmographyProvider`: the bio and server titles
//  first, then TMDB's combined credits merged with them, then the titles on
//  the user's other servers marked. Filters start fresh on every open.
//  `onSelectItem` reports a tapped poster's MediaItem back to the presenter.
//

import UIKit
import os.log

private let personLog = Logger(subsystem: "com.rivulet.app", category: "PersonDetail")

@MainActor
final class PersonDetailViewController: UIViewController {

    // MARK: - Public

    /// Reports the MediaItem behind a tapped poster (server or metadata-only).
    var onSelectItem: ((MediaItem) -> Void)?

    // MARK: - Section / item model

    private enum Section: Int, CaseIterable {
        case header
        case filters
        case grid
    }

    /// Diffable item identity: one each for the header and the filter row,
    /// one per title in the grid (keyed by `FilmographyEntry.key`).
    /// `nonisolated` + `Sendable` so its Hashable conformance satisfies the
    /// diffable data source's `Sendable` ItemIdentifierType requirement under
    /// Swift 6 (the enclosing VC is @MainActor-isolated).
    nonisolated private struct ItemID: Hashable, Sendable {
        let section: Int
        let token: String
    }

    private static let headerItem = ItemID(section: Section.header.rawValue, token: "header")
    private static let filtersItem = ItemID(section: Section.filters.rawValue, token: "filters")

    // MARK: - Dependencies / state

    private let person: MediaPerson
    private let provider: PersonFilmographyProviding

    private var detail: PersonDetail?
    /// Every title, unfiltered.
    private var entries: [FilmographyEntry] = []
    /// `entries` through `query`: what the grid shows.
    private var visibleEntries: [FilmographyEntry] = []
    private var query = FilmographyQuery()
    /// True from first paint until the provider returns — drives the header's
    /// loading dots so the page reads as "working".
    private var isLoading = true

    /// The current section layout, in display order. The filter row and the
    /// grid appear once there is a title to filter.
    private var sections: [Section] = [.header]

    private var loadTask: Task<Void, Never>?

    // MARK: - Views

    private let gradientLayer = CAGradientLayer()
    /// Full-bleed backdrop image from the originating title. Hidden when no URL.
    private let backdropImageView = UIImageView()
    /// Dark blur over the backdrop to keep text readable.
    private let backdropBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// Subtle dark scrim (0.35 alpha black) on top of the blur for legibility.
    private let backdropScrimView = UIView()
    private var collectionView: FocusScrollControlledCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ItemID>!

    /// Blur-fade dissolve in/out (same transition as navigating to a related
    /// item from the expanded detail). Retained for the lifetime of the VC —
    /// the transitioning delegate is held weakly by UIKit.
    private let blurFade = BlurFadeTransitioningDelegate()

    // MARK: - Init

    init(person: MediaPerson, provider: PersonFilmographyProviding = PersonFilmographyProvider()) {
        self.person = person
        self.provider = provider
        super.init(nibName: nil, bundle: nil)
        // Blur-fade dissolve over whatever's behind (the previous detail), kept
        // visible because it's presented over another modal — same as the
        // standalone related-item detail. .overFullScreen so the blur reads.
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = blurFade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PersonDetailViewController is not Storyboard-backed") }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureBackdrop()
        configureGradient()
        configureCollectionView()
        configureDataSource()

        // Show the skeleton/empty state immediately, then fetch.
        applySnapshot(animated: false)
        loadTask = Task { [weak self] in await self?.reload() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Express focus here (not viewDidLoad/viewWillAppear): the view is in
        // the window now, so setNeedsFocusUpdate resolves to a real target.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Prefer the header's bio panel so focus starts on the DESCRIPTION, not
        // a poster row. The panel is focusable from first paint (it shows the
        // loading dots until the bio arrives), so this resolves even pre-load.
        // Fall back to the collection if the header cell isn't realized yet.
        let headerPath = IndexPath(item: 0, section: 0)
        if sections.first == .header,
           let header = collectionView.cellForItem(at: headerPath) {
            return [header]
        }
        return [collectionView]
    }

    // MARK: - Setup

    /// Blurred backdrop layer — the originating title's art behind everything.
    /// Falls back to the existing gradient when `person.backdropURL` is nil.
    private func configureBackdrop() {
        guard let url = person.backdropURL else { return }

        // All three views are pinned full-bleed (ignore safe area — backdrops
        // should reach screen edges, matching the tvOS HIG backdrop convention).
        backdropImageView.translatesAutoresizingMaskIntoConstraints = false
        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        backdropImageView.alpha = 0  // Fade in once the image loads

        backdropBlurView.translatesAutoresizingMaskIntoConstraints = false

        backdropScrimView.translatesAutoresizingMaskIntoConstraints = false
        backdropScrimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        // Insert below the gradient and collection view so focus/interaction is
        // unaffected. Insertion order: imageView → blurView → scrimView, then the
        // existing gradientLayer (a sublayer) sits on top for color-grading.
        view.insertSubview(backdropImageView, at: 0)
        view.insertSubview(backdropBlurView, aboveSubview: backdropImageView)
        view.insertSubview(backdropScrimView, aboveSubview: backdropBlurView)

        let edgeConstraints: (UIView) -> [NSLayoutConstraint] = { v in
            [
                v.topAnchor.constraint(equalTo: self.view.topAnchor),
                v.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(
            edgeConstraints(backdropImageView) +
            edgeConstraints(backdropBlurView) +
            edgeConstraints(backdropScrimView)
        )

        // Load the image off-main using the same ImageCacheManager pattern as
        // CastCell / PersonHeaderCell — no new dependency.
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self, let image else { return }
                self.backdropImageView.image = image
                UIView.animate(withDuration: 0.4) {
                    self.backdropImageView.alpha = 1
                }
            }
        }
    }

    /// Dark blue → black vertical gradient, less artwork-specific than the show
    /// detail pages (ref: "dark blue/black gradient").
    private func configureGradient() {
        gradientLayer.colors = [
            UIColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1).cgColor,
            UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor,
            UIColor.black.cgColor,
        ]
        gradientLayer.locations = [0.0, 0.6, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        view.layer.insertSublayer(gradientLayer, at: 0)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            self?.layoutSection(at: sectionIndex, environment: environment)
        }
        collectionView = FocusScrollControlledCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.clipsToBounds = false
        // Hand the vertical focus-scroll to FocusScrollControlledCollectionView:
        // disabling the engine's own scroll animator stops it racing the
        // subclass's per-frame CADisplayLink driver (same as BelowFoldCollectionView).
        // topSectionIndex stays nil so every focused row centers — no pinned top band.
        collectionView.isScrollEnabled = false
        collectionView.delegate = self
        collectionView.register(PersonHeaderCell.self, forCellWithReuseIdentifier: PersonHeaderCell.reuseID)
        collectionView.register(WatchlistFilterHeaderControl.self,
                                forCellWithReuseIdentifier: WatchlistFilterHeaderControl.reuseID)
        collectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, ItemID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, itemID in
            self?.cell(for: itemID, at: indexPath, in: collectionView)
        }
    }

    // MARK: - Layout

    private func layoutSection(at sectionIndex: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard sectionIndex < sections.count else { return nil }
        switch sections[sectionIndex] {
        case .header:  return makeHeaderSectionLayout()
        case .filters: return makeFiltersSectionLayout()
        case .grid:    return makeGridSectionLayout()
        }
    }

    /// Full-width header (portrait + name + bio + MORE). Estimated height; the
    /// cell hugs its content. Leading/trailing match the shared content margin.
    private func makeHeaderSectionLayout() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .estimated(280))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 80,
            leading: MediaRowMetrics.rowLeading,
            bottom: 14,
            trailing: MediaRowMetrics.rowTrailing)
        return section
    }

    /// The filter row: the Watchlist header's own section shape.
    private func makeFiltersSectionLayout() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(96))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: MediaRowMetrics.rowLeading, bottom: 24, trailing: MediaRowMetrics.rowTrailing)
        return section
    }

    /// Six across on the shared grid, like the Watchlist grid, each tile
    /// tall enough for its caption.
    private func makeGridSectionLayout() -> NSCollectionLayoutSection {
        let tile = MediaRowMetrics.poster
        let groupHeight = tile.frame.height + WatchlistPosterCell.captionHeight + MediaRowMetrics.focusGrowthPadding / 2
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(MediaRowMetrics.posterFullCount)),
            heightDimension: .absolute(groupHeight)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(groupHeight)),
            repeatingSubitem: item,
            count: MediaRowMetrics.posterFullCount)
        group.interItemSpacing = .fixed(tile.gap)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.interGroupSpacing = 24
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: tile.leading, bottom: 80, trailing: tile.leading)
        return section
    }

    // MARK: - Cells

    private func cell(for itemID: ItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sections.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PersonHeaderCell.reuseID, for: indexPath)
        }
        switch sections[indexPath.section] {
        case .header:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PersonHeaderCell.reuseID, for: indexPath) as! PersonHeaderCell
            configureHeader(cell)
            return cell
        case .filters:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: WatchlistFilterHeaderControl.reuseID, for: indexPath) as! WatchlistFilterHeaderControl
            configureFilters(cell)
            return cell
        case .grid:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: WatchlistPosterCell.reuseID, for: indexPath) as! WatchlistPosterCell
            if let entry = visibleEntries[safe: indexPath.item] {
                cell.configure(
                    item: entry.item,
                    badge: entry.isOnServer ? "On Server" : nil,
                    caption: .init(title: entry.item.title,
                                   detail: entry.item.year.map(String.init),
                                   credit: entry.credit))
            }
            return cell
        }
    }

    private func configureHeader(_ cell: PersonHeaderCell) {
        cell.configure(
            name: detail?.name ?? person.name,
            biography: detail?.biography,
            // Always the Plex thumb — identical before/after load so the
            // portrait never visibly swaps when the bio arrives.
            portraitURL: person.imageURL,
            isLoading: isLoading,
            onMore: { [weak self] in self?.presentBiography() })
    }

    private func configureFilters(_ cell: WatchlistFilterHeaderControl) {
        cell.configure(
            title: "Filmography",
            count: visibleEntries.count,
            sortName: query.sort.displayName,
            typeName: query.type.displayName,
            genreName: genreButtonLabel,
            countNoun: ("title", "titles"),
            toggle: ("On My Servers", query.onMyServersOnly))
        cell.onSortTapped = { [weak self] in self?.presentSortPicker() }
        cell.onTypeTapped = { [weak self] in self?.presentTypePicker() }
        cell.onGenreTapped = { [weak self, weak cell] in
            guard let cell else { return }
            self?.presentGenrePicker(from: cell.genreButtonView)
        }
        cell.onToggleTapped = { [weak self] in
            guard let self else { return }
            self.query.onMyServersOnly.toggle()
            self.applySnapshot(animated: false)
        }
    }

    // MARK: - Filters

    /// The Watchlist's Genre label rule: "All Genres", one name, "A + B"
    /// while it fits, else a count.
    private var genreButtonLabel: String {
        switch query.genres.count {
        case 0: return "All Genres"
        case 1: return query.genres.first!
        default:
            let joined = query.genres.sorted().joined(separator: " + ")
            return joined.count <= 24 ? joined : "\(query.genres.count) Genres"
        }
    }

    private func presentSortPicker() {
        let sheet = UIAlertController(title: "Sort By", message: nil, preferredStyle: .actionSheet)
        for option in FilmographySortOption.allCases {
            let title = option == query.sort ? "\u{2713} \(option.displayName)" : option.displayName
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self, option != self.query.sort else { return }
                self.query.sort = option
                self.applySnapshot(animated: false)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentTypePicker() {
        let sheet = UIAlertController(title: "Show", message: nil, preferredStyle: .actionSheet)
        for option in WatchlistTypeFilter.allCases {
            let title = option == query.type ? "\u{2713} \(option.displayName)" : option.displayName
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self, option != self.query.type else { return }
                self.query.type = option
                self.applySnapshot(animated: false)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// The Watchlist's multi-select Genre popup: AND across the picks, a
    /// live count, Done or Menu applies.
    private func presentGenrePicker(from button: UIView) {
        let genres = Set(entries.flatMap(\.genres)).sorted()
        let popup = WatchlistGenreFilterPopupViewController(
            genres: genres,
            selected: query.genres,
            sourceFrame: button.convert(button.bounds, to: nil),
            countProvider: { [weak self] candidate in
                guard let self else { return 0 }
                return self.query.filtered(self.entries, genres: candidate).count
            },
            onApply: { [weak self] picked in
                guard let self, picked != self.query.genres else { return }
                self.query.genres = picked
                self.applySnapshot(animated: false)
            })
        present(popup, animated: false)
    }

    // MARK: - Data

    private func reload() async {
        let start = ContinuousClock.now
        let loaded: PersonDetail
        do {
            loaded = try await provider.load(person: person)
        } catch {
            // The provider degrades gracefully for the no-token / fetch-error
            // case, but can still throw — show name + portrait with an empty
            // filmography rather than crashing.
            loaded = PersonDetail(
                id: person.tagKey ?? person.id,
                name: person.name,
                biography: nil,
                portraitURL: person.imageURL,
                movies: [],
                shows: [])
        }
        if Task.isCancelled { return }

        // Bio and the server's own titles first, so the page is never empty
        // while TMDB answers.
        detail = loaded
        let onServer = loaded.movies + loaded.shows
        entries = onServer
        isLoading = false
        applySnapshot(animated: false)
        personLog.info("[Person] bio + \(onServer.count, privacy: .public) server title(s) in \(Self.ms(since: start), privacy: .public)ms")

        entries = await provider.filmography(person: person, onServer: onServer)
        if Task.isCancelled { return }
        applySnapshot(animated: false)
        personLog.info("[Person] filmography \(self.entries.count, privacy: .public) title(s) in \(Self.ms(since: start), privacy: .public)ms")

        // Other servers last, a batch at a time in the grid's own order, so
        // the badges on screen land first and the grid never waits on them.
        let order = query.apply(entries).map(\.key)
        for batchStart in stride(from: 0, to: order.count, by: 24) {
            let keys = Set(order[batchStart..<min(batchStart + 24, order.count)])
            let batch = entries.filter { keys.contains($0.key) }
            let marked = await provider.markingOtherServers(batch)
            if Task.isCancelled { return }
            let found = Set(marked.filter(\.isOnServer).map(\.key))
            guard !found.isEmpty else { continue }
            for index in entries.indices where found.contains(entries[index].key) {
                entries[index].isOnServer = true
            }
            applySnapshot(animated: false)
        }
        personLog.info("[Person] other servers checked in \(Self.ms(since: start), privacy: .public)ms")
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func applySnapshot(animated: Bool) {
        visibleEntries = query.apply(entries)
        var visible: [Section] = [.header]
        // The filter row stays once there is anything to filter, so a filter
        // that matches nothing can still be undone.
        if !entries.isEmpty { visible += [.filters, .grid] }
        sections = visible

        var snapshot = NSDiffableDataSourceSnapshot<Int, ItemID>()
        for section in visible {
            snapshot.appendSections([section.rawValue])
            switch section {
            case .header: snapshot.appendItems([Self.headerItem], toSection: section.rawValue)
            case .filters: snapshot.appendItems([Self.filtersItem], toSection: section.rawValue)
            case .grid:
                var seen = Set<String>()
                let ids = visibleEntries.compactMap { entry -> ItemID? in
                    guard seen.insert(entry.key).inserted else { return nil }
                    return ItemID(section: section.rawValue, token: entry.key)
                }
                snapshot.appendItems(ids, toSection: section.rawValue)
            }
        }
        // Identity is the title, so a badge or caption change needs a reconfigure.
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: - Biography popup

    private func presentBiography() {
        guard let detail, let bio = detail.biography, !bio.isEmpty else { return }
        let content = InfoPopupContent.description(title: detail.name, subtitle: nil, body: bio)
        let popup = InfoPopupViewController(content: content, width: 840, scrollable: true)
        present(popup, animated: true)
    }
}

extension PersonDetailViewController: UICollectionViewDelegate {
    /// A grid title opens its normal detail page: the playable one when it's
    /// on the selected server, else the metadata-only one (whose On Your
    /// Servers row plays a copy on another server).
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard sections[safe: indexPath.section] == .grid,
              let entry = visibleEntries[safe: indexPath.item] else { return }
        onSelectItem?(entry.item)
    }
}

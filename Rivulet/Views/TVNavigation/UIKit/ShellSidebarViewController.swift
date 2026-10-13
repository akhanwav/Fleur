// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShellSidebarViewController.swift
//  Rivulet
//
//  The custom shell sidebar, embedded in RootShellViewController. Sizes and
//  type come from the Apple TV app's own sidebar.
//

import UIKit

// MARK: - Metrics

private enum Metrics {
    /// Values are the Apple TV app's own sidebar where one was read; the panel
    /// frame, pill origin and morph timing are still the system sidebar's.
    static let panelWidth: CGFloat = 340
    static let panelInset: CGFloat = 35
    /// The Apple TV app's panel radius, not the system tab sidebar's 52.
    static let panelCornerRadius: CGFloat = 40
    /// The TV app's section insets: rows sit 10pt inside the glass.
    static let contentLeading: CGFloat = 10
    static let contentTrailing: CGFloat = 10
    /// 55 (list top inset, window) - 36 (panel inset).
    static let contentTop: CGFloat = 19
    static let contentBottom: CGFloat = 15
    static let rowPitch: CGFloat = 78
    /// The TV app's focus platter: 72pt tall, 3pt inside the 78pt row.
    static let capsuleHeight: CGFloat = 72
    /// The TV app's row columns: icon centred in a 72pt leading column, title
    /// 2pt after it, 16pt trailing margin.
    static let iconCenterX: CGFloat = 36
    static let titleLeading: CGFloat = 74
    static let titleTrailing: CGFloat = 16
    static var capsuleRadius: CGFloat { capsuleHeight / 2 }
    static var capsuleVerticalInset: CGFloat { (rowPitch - capsuleHeight) / 2 }
    static let sectionGap: CGFloat = 70
    static let pillOrigin = CGPoint(x: 50, y: 50)
    static let pillHeight: CGFloat = 60
    /// The TV app's 46pt icon box, centred in the 60pt pill.
    static let pillDiscSize: CGFloat = 46
    static var pillDiscInset: CGFloat { (pillHeight - pillDiscSize) / 2 }
    static let pillTrailing: CGFloat = 24
    /// The TV app's sidebar avatar.
    static let avatarSize: CGFloat = 50
    /// USER-VERIFIED on screen: the single spring crossfade reads nearly
    /// identical to the system morph; a literal three-phase re-timing from
    /// the 120fps frame analysis read distinctly WORSE and was reverted.
    /// Trust the A/B eyeball over tile-level frame forensics here.
    static let morphDuration: TimeInterval = 0.45
    static let morphDamping: CGFloat = 0.9
    static let dimAlpha: CGFloat = 0.35
    /// Darkens the glass toward the system sidebar's tone; the sole knob for
    /// the material tuning pass, to be converged against sampled pixels.
    static let glassTint = UIColor.black.withAlphaComponent(0.12)
}

/// How far down a page's own content has to start to clear the collapsed pill.
///
/// The pill draws over the top-left of whatever tab is mounted, and it only
/// hides once focus moves below the top row — so anything a page puts at its
/// own top edge renders under it. Home with the hero off put the first row's
/// title there (#298) and Search put the text field there (#292).
enum ShellPillMetrics {
    /// Pill bottom (50 + 60) plus a small gap.
    static let contentClearance: CGFloat = Metrics.pillOrigin.y + Metrics.pillHeight + 14
}

/// System row coloring: focused = solid white capsule, dark content; selected
/// but unfocused = translucent capsule, full-white content; otherwise bare, dim.
/// Resting 0.7 is the TV app's value; its focused 0.9 / 0.7 pair rides a
/// PlusL / PlusD layer this sidebar does not have.
private func sidebarRowColors(focused: Bool, selected: Bool) -> (background: UIColor, content: UIColor) {
    if focused { return (.white, .black) }
    if selected { return (UIColor.white.withAlphaComponent(0.1), .white) }
    return (.clear, UIColor.white.withAlphaComponent(0.7))
}

/// The text style's font at the emphasized (bold) weight, as the TV app asks
/// for it: from the style, never a hard-coded size.
private func emphasizedFont(_ style: UIFont.TextStyle) -> UIFont {
    let base = UIFont.preferredFont(forTextStyle: style)
    return base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base
}

/// A round profile picture drawn over a glyph, which shows until it loads.
private final class SidebarAvatarView: UIImageView {
    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            image = url.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
            guard let url, image == nil else { return }
            Task { [weak self] in
                let loaded = await ImageCacheManager.shared.image(for: url)
                if self?.url == url { self?.image = loaded }
            }
        }
    }

    init(diameter: CGFloat) {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = diameter / 2
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter),
                                     heightAnchor.constraint(equalToConstant: diameter)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Collection view

/// Directs its opening focus at a specific row. `remembersLastFocusedIndexPath`
/// only restores the last-touched cell; the sidebar needs the SELECTED tab
/// focused on every open, so it sets `preferredFocusIndexPath` first.
final class SidebarCollectionView: UICollectionView {
    var preferredFocusIndexPath: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // The cell must exist right now, or the engine ignores this and falls
        // back to its own pick (realized in aimInitialFocus).
        if let indexPath = preferredFocusIndexPath, let cell = cellForItem(at: indexPath) {
            return [cell]
        }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // The aim is for the OPENING move only, and nothing was clearing it.
        // Left set, EVERY later focus update while the sidebar was open
        // resolved back through it to the selected row — so the expand
        // animator's completion, which requests focus ~0.3s after opening,
        // yanked the user back from whatever row they had already moved to.
        // The next open re-aims via `aimInitialFocus`.
        if let next = context.nextFocusedItem as? UIView, next.isDescendant(of: self) {
            preferredFocusIndexPath = nil
        }
    }
}

// MARK: - Row cell

final class ShellSidebarRowCell: UICollectionViewCell {
    static let reuseIdentifier = "ShellSidebarRowCell"

    private let backgroundPill = UIView()
    private let iconView = UIImageView()
    private let avatarView = SidebarAvatarView(diameter: Metrics.avatarSize)
    private let titleLabel = UILabel()
    private var isSelectedTab = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundPill.layer.cornerRadius = Metrics.capsuleRadius
        backgroundPill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backgroundPill)

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        for view in [iconView, titleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        contentView.addSubview(avatarView)

        NSLayoutConstraint.activate([
            avatarView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            avatarView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            backgroundPill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundPill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundPill.topAnchor.constraint(equalTo: contentView.topAnchor,
                                                constant: Metrics.capsuleVerticalInset),
            backgroundPill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor,
                                                   constant: -Metrics.capsuleVerticalInset),
            iconView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor,
                                              constant: Metrics.iconCenterX),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                                constant: Metrics.titleLeading),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor,
                                                 constant: -Metrics.titleTrailing),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyAppearance(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: ShellSidebarItem, isSelectedTab: Bool) {
        self.isSelectedTab = isSelectedTab
        iconView.image = UIImage(systemName: item.icon)
        avatarView.url = item.avatarURL
        titleLabel.text = item.title
        applyAppearance(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused {
            coordinator.addCoordinatedAnimations({ self.applyAppearance(focused: true) })
        } else {
            // Clear instantly: running the unfocus through the coordinator
            // leaves the old row's white capsule ghosting behind the move.
            applyAppearance(focused: false)
        }
    }

    private func applyAppearance(focused: Bool) {
        let colors = sidebarRowColors(focused: focused, selected: isSelectedTab)
        backgroundPill.backgroundColor = colors.background
        iconView.tintColor = colors.content
        titleLabel.textColor = colors.content
    }
}

// MARK: - Section header

final class ShellSidebarHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "ShellSidebarHeaderView"
    static let elementKind = "ShellSidebarHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = emphasizedFont(.caption2)
        label.textColor = .tertiaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Controller

final class ShellSidebarViewController: UIViewController {

    private enum State { case expanded, collapsed }

    private var state: State = .expanded
    private var sections: [ShellSidebarSection] = []
    private var selectedTab: SidebarTab = .home

    private let dimmingView = UIView()
    /// ONE glass card morphs between panel and pill, as the trace showed the
    /// system does: frame and corner radius animate together on one spring;
    /// the list fades out and clips inside the shrinking card while the pill
    /// content fades in.
    private let cardView = UIView()
    private let glassView: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = Metrics.glassTint
        return UIVisualEffectView(effect: effect)
    }()
    /// `chevron.compact.left` at callout size, as the TV app's pill draws it.
    private let pillChevron = UIImageView(image: UIImage(
        systemName: "chevron.compact.left",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .callout)))
    private let pillIcon = UIImageView()
    private let pillIconDisc = UIView()
    private let pillAvatar = SidebarAvatarView(diameter: Metrics.pillDiscSize)
    private let pillLabel = UILabel()
    private let pillStack = UIStackView()
    private var collectionView: SidebarCollectionView!
    private var transitionAnimator: UIViewPropertyAnimator?

    // MARK: Shell integration
    // When embedded, RootShellViewController owns expansion, focus handoff,
    // and tab authority; the sidebar reports intent through these callbacks.
    // The preview modal path keeps `embedded` false and self-drives.
    var embedded = false
    var onTabSelected: ((SidebarTab) -> Void)?
    var onCollapseRequested: (() -> Void)?
    private var pillHidden = false
    /// While the profile panel is up the pill names the user, not the tab.
    private var pillShowsProfile = false

    var isExpanded: Bool { state == .expanded }
    var focusTarget: UIView { collectionView }

    func setPillShowsProfile(_ shows: Bool) {
        pillShowsProfile = shows
        configurePill()
    }

    /// `aimAt` opens on that row instead of the selected tab's.
    func setExpanded(_ expanded: Bool, animated: Bool, aimAt tab: SidebarTab? = nil) {
        if expanded { aimInitialFocus(at: tab ?? selectedTab) }
        setState(expanded ? .expanded : .collapsed)
        if !animated {
            transitionAnimator?.stopAnimation(false)
            transitionAnimator?.finishAnimation(at: .end)
        }
    }

    /// Directs the sidebar's opening focus at the currently selected tab's
    /// row (Home opens on Home, Settings on Settings). The cell must be
    /// realized before the focus engine reads `preferredFocusEnvironments`,
    /// so unhide + lay out + scroll it into view first.
    private func aimInitialFocus(at tab: SidebarTab) {
        guard let indexPath = indexPath(for: tab) else {
            collectionView.preferredFocusIndexPath = nil
            return
        }
        collectionView.isHidden = false
        collectionView.preferredFocusIndexPath = indexPath
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
    }

    private func indexPath(for tab: SidebarTab) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.tab == tab }) {
                return IndexPath(item: i, section: s)
            }
        }
        return nil
    }

    /// Selection pushed down from the shell (SwiftUI is the tab authority).
    func setSelectedTabExternal(_ tab: SidebarTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        configurePill()
        collectionView.reloadData()
    }

    /// Live section updates pushed from SwiftUI, which observes every store
    /// that feeds the sidebar. Diffed, so idle updates cost nothing; no
    /// snapshot dance, the whole point of owning the shell.
    func setSections(_ new: [ShellSidebarSection]) {
        guard new != sections else { return }
        sections = new
        guard isViewLoaded else { return }
        collectionView.reloadData()
        configurePill()
    }

    /// Collapsed-state pill visibility, driven by the below-top focus signal.
    func setPillHidden(_ hidden: Bool) {
        pillHidden = hidden
        guard state == .collapsed, transitionAnimator == nil else { return }
        UIView.animate(withDuration: 0.18) {
            self.cardView.alpha = hidden ? 0 : 1
            self.pillChevron.alpha = hidden ? 0 : 1
        }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        sections = Self.liveSections()
        buildViews()
        configurePill()
        applyState(expanded: true, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard transitionAnimator == nil else { return }
        cardView.frame = state == .expanded ? panelFrame : pillFrame
        layoutListInCard()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        state == .expanded ? [collectionView] : []
    }

    // MARK: Input

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch (press.type, state) {
            case (.rightArrow, .expanded):
                if embedded { onCollapseRequested?() } else { setState(.collapsed) }
                return
            case (.leftArrow, .collapsed) where !embedded:
                setState(.expanded)
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Morph

    private var panelFrame: CGRect {
        CGRect(x: Metrics.panelInset, y: Metrics.panelInset,
               width: Metrics.panelWidth,
               height: view.bounds.height - 2 * Metrics.panelInset)
    }

    private var pillFrame: CGRect {
        let content = pillStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGRect(x: Metrics.pillOrigin.x, y: Metrics.pillOrigin.y,
                      width: content.width + Metrics.pillDiscInset + Metrics.pillTrailing,
                      height: Metrics.pillHeight)
    }

    private func setState(_ newState: State) {
        guard newState != state, transitionAnimator == nil else { return }
        state = newState
        applyState(expanded: newState == .expanded, animated: true)
    }

    private func applyState(expanded: Bool, animated: Bool) {
        let targetFrame = expanded ? panelFrame : pillFrame
        let targetRadius = expanded ? Metrics.panelCornerRadius : Metrics.pillHeight / 2
        collectionView.isHidden = false
        cardView.alpha = 1
        // The chevron belongs to the collapsed pill only; it never shows while
        // the panel is open.
        let chevronTarget: CGFloat = expanded ? 0 : (pillHidden ? 0 : 1)
        guard animated else {
            cardView.frame = targetFrame
            cardView.layer.cornerRadius = targetRadius
            dimmingView.alpha = expanded ? Metrics.dimAlpha : 0
            collectionView.alpha = expanded ? 1 : 0
            pillStack.alpha = expanded ? 0 : 1
            pillChevron.alpha = chevronTarget
            collectionView.isHidden = !expanded
            if !expanded, pillHidden { cardView.alpha = 0 }
            view.setNeedsLayout()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        let animator = UIViewPropertyAnimator(duration: Metrics.morphDuration,
                                              dampingRatio: Metrics.morphDamping) {
            self.cardView.frame = targetFrame
            self.cardView.layer.cornerRadius = targetRadius
            self.dimmingView.alpha = expanded ? Metrics.dimAlpha : 0
            self.collectionView.alpha = expanded ? 1 : 0
            self.pillStack.alpha = expanded ? 0 : 1
            self.pillChevron.alpha = chevronTarget
        }
        animator.addCompletion { _ in
            self.transitionAnimator = nil
            // The pill's title can change mid-morph (Menu to Home): fit it now.
            self.view.setNeedsLayout()
            if self.state == .collapsed {
                // A hidden list is invisible to the focus engine; alpha 0 is not.
                self.collectionView.isHidden = true
                // pillHidden can flip mid-morph: a below-top focus change posts
                // while this animator is in flight, and setPillHidden bails on a
                // live transition. Reconcile BOTH the card and its chevron here,
                // or the chevron is left stranded visible over a hidden pill.
                let pillAlpha: CGFloat = self.pillHidden ? 0 : 1
                self.cardView.alpha = pillAlpha
                self.pillChevron.alpha = pillAlpha
            }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    // MARK: Views

    private func buildViews() {
        dimmingView.backgroundColor = .black
        dimmingView.frame = view.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimmingView)

        cardView.layer.cornerCurve = .continuous
        cardView.layer.masksToBounds = true
        view.addSubview(cardView)

        glassView.frame = cardView.bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardView.addSubview(glassView)

        collectionView = SidebarCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        // The card is the frame of reference; without this the scroll view
        // adds the window safe-area top (6pt at this geometry) to the list.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        // Off: initial focus is directed at the selected tab, not the last
        // one the user happened to touch (see aimInitialFocus).
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(ShellSidebarRowCell.self,
                                forCellWithReuseIdentifier: ShellSidebarRowCell.reuseIdentifier)
        collectionView.register(ShellSidebarHeaderView.self,
                                forSupplementaryViewOfKind: ShellSidebarHeaderView.elementKind,
                                withReuseIdentifier: ShellSidebarHeaderView.reuseIdentifier)
        cardView.addSubview(collectionView)

        // Back-chevron, as the system pill shows: OUTSIDE the capsule, to its
        // left, white. Lives on the main view (not the glass card) so it sits
        // outside the glass, and fades with the pill.
        pillChevron.tintColor = .white
        pillChevron.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pillChevron)

        pillIcon.tintColor = .white
        pillIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        pillIcon.translatesAutoresizingMaskIntoConstraints = false
        // Disc tone is a photo estimate; the TV app's colour was not read.
        pillIconDisc.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        pillIconDisc.layer.cornerRadius = Metrics.pillDiscSize / 2
        pillIconDisc.addSubview(pillIcon)
        pillIconDisc.addSubview(pillAvatar)
        pillLabel.font = emphasizedFont(.body)
        pillLabel.textColor = .white
        pillStack.addArrangedSubview(pillIconDisc)
        pillStack.addArrangedSubview(pillLabel)
        pillStack.axis = .horizontal
        pillStack.spacing = 12
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(pillStack)

        NSLayoutConstraint.activate([
            pillIconDisc.widthAnchor.constraint(equalToConstant: Metrics.pillDiscSize),
            pillIconDisc.heightAnchor.constraint(equalToConstant: Metrics.pillDiscSize),
            pillIcon.centerXAnchor.constraint(equalTo: pillIconDisc.centerXAnchor),
            pillIcon.centerYAnchor.constraint(equalTo: pillIconDisc.centerYAnchor),
            pillAvatar.centerXAnchor.constraint(equalTo: pillIconDisc.centerXAnchor),
            pillAvatar.centerYAnchor.constraint(equalTo: pillIconDisc.centerYAnchor),
            pillStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor,
                                               constant: Metrics.pillDiscInset),
            pillStack.centerYAnchor.constraint(equalTo: cardView.topAnchor,
                                               constant: Metrics.pillHeight / 2),
            // Chevron sits just left of the collapsed pill, vertically centered
            // on it. The pill's left edge is at pillOrigin.x.
            pillChevron.trailingAnchor.constraint(equalTo: view.leadingAnchor,
                                                  constant: Metrics.pillOrigin.x - 12),
            pillChevron.centerYAnchor.constraint(equalTo: view.topAnchor,
                                                 constant: Metrics.pillOrigin.y + Metrics.pillHeight / 2),
        ])
    }

    /// The list keeps its full panel-state size and lets the shrinking card
    /// CLIP it (with a fade), matching the portal look of the system morph;
    /// resizing the list itself would squish rows mid-animation.
    private func layoutListInCard() {
        collectionView.frame = CGRect(
            x: Metrics.contentLeading,
            y: Metrics.contentTop,
            width: Metrics.panelWidth - Metrics.contentLeading - Metrics.contentTrailing,
            height: panelFrame.height - Metrics.contentTop - Metrics.contentBottom)
    }

    private func configurePill() {
        let item = item(for: pillShowsProfile ? .account : selectedTab)
        pillIcon.image = UIImage(systemName: item.icon)
        pillAvatar.url = item.avatarURL
        pillLabel.text = item.title
        // The pill is as wide as its title: resize it when it is at rest.
        view.setNeedsLayout()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                  heightDimension: .absolute(Metrics.rowPitch))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            // Window safe-area insets (80 leading / 60 top) must not shift
            // rows: the card's own geometry is the only frame of reference.
            section.contentInsetsReference = .none
            section.interGroupSpacing = 0
            // Measured: every section break is one 70pt gap; a titled section
            // draws its header inside the gap, an untitled one leaves it empty.
            if self?.sections[sectionIndex].title != nil {
                let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                        heightDimension: .absolute(Metrics.sectionGap))
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: headerSize,
                        elementKind: ShellSidebarHeaderView.elementKind,
                        alignment: .top)
                ]
            } else if sectionIndex > 0 {
                section.contentInsets = NSDirectionalEdgeInsets(top: Metrics.sectionGap,
                                                                leading: 0, bottom: 0, trailing: 0)
            }
            return section
        }
    }

    // MARK: Data

    private static func liveSections() -> [ShellSidebarSection] {
        let defaults = UserDefaults.standard
        func flag(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        let profileName = PlexUserProfileManager.shared.selectedUser?.displayName
            ?? PlexAuthManager.shared.username
            ?? "Account"
        return ShellSidebarModel.sections(
            libraries: PlexDataStore.shared.visibleMediaLibraries,
            liveTVSources: LiveTVDataStore.shared.sources,
            combineLiveTV: flag("combineLiveTVSources", default: true),
            showDiscover: flag("showDiscoverTab", default: true),
            discoverAbove: flag("discoverAboveLibraries", default: true),
            showWatchlist: flag("showWatchlistTab", default: true),
            liveTVAbove: flag("liveTVAboveLibraries", default: false),
            serverName: PlexAuthManager.shared.savedServerName,
            profileName: profileName)
    }

    private func item(for tab: SidebarTab) -> ShellSidebarItem {
        for section in sections {
            if let match = section.items.first(where: { $0.tab == tab }) { return match }
        }
        return ShellSidebarItem(tab: .home, title: "Home", icon: "house.fill")
    }

}

// MARK: - Collection view

extension ShellSidebarViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ShellSidebarRowCell.reuseIdentifier,
            for: indexPath) as! ShellSidebarRowCell
        let item = sections[indexPath.section].items[indexPath.item]
        cell.configure(item: item, isSelectedTab: item.tab == selectedTab)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: ShellSidebarHeaderView.reuseIdentifier,
            for: indexPath) as! ShellSidebarHeaderView
        header.label.text = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let tab = sections[indexPath.section].items[indexPath.item].tab
        if tab != .account { select(tab: tab) }
        if embedded { onTabSelected?(tab) }
    }

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        // Containment: while expanded, focus stays inside the sidebar; the
        // shell moves it out explicitly on collapse (state flips first, so
        // that move is never blocked).
        guard embedded, state == .expanded else { return true }
        if let nextView = context.nextFocusedView, !nextView.isDescendant(of: view) {
            return false
        }
        return true
    }

    private func select(tab: SidebarTab) {
        selectedTab = tab
        configurePill()
        collectionView.reloadData()
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerTopPanelView.swift
//  Rivulet
//
//  Content for the player's top quick-adjust panel
//  (PlayerRailPanelView.presentTop): a tab bar (Video/Audio/Subtitles) over
//  a content area that swaps per tab.
//
//  Every move here — Left/Right between pills, Down into the active tab's
//  controls, Up back out to the tab bar, Up from the tab bar closing the
//  panel — is handled EXPLICITLY in code, not left to the focus engine's
//  own directional search. That search was diagnosed (temporary focus
//  logging, since reverted) to never once propose a sibling pill or the
//  content below as a candidate from inside this panel, for reasons that
//  didn't resolve with the fixes that normally cover this ground elsewhere
//  in the file (CardTrackListView's `onDownAtEnd`/`onUpAtStart`, a
//  `lastFocusedPill` fix mirroring `PlayerRailView.lastFocusedButton`).
//  Rather than a third theory about the engine's internals, every
//  direction here now just calls `setNeedsFocusUpdate()`/`updateFocusIfNeeded()`
//  from an environment that currently contains focus, same mechanism
//  `focusActiveTab()`/`focusTabBar()` already used reliably for the
//  dismiss-on-Up path.
//

import UIKit

enum PlayerTopPanelTab: String, CaseIterable {
    case video
    case audio
    case subtitles

    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        }
    }

    private static let lastUsedKey = "topPanelLastTab"

    /// Remembered across opens of the panel; Video the first time.
    static var lastUsed: PlayerTopPanelTab {
        get {
            guard let raw = UserDefaults.standard.string(forKey: lastUsedKey) else { return .video }
            return PlayerTopPanelTab(rawValue: raw) ?? .video
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastUsedKey) }
    }
}

// MARK: - PlayerTopPanelTabBar

/// Three pills, reusing `PlayerInfoPillButton` as-is (it's already a
/// standalone control, not coupled to `PlayerRailView`'s own layout).
final class PlayerTopPanelTabBar: UIView {
    private enum Metrics {
        static let gap: CGFloat = 16
    }

    var onTabChanged: ((PlayerTopPanelTab) -> Void)?
    var onCloseRequested: (() -> Void)?
    /// Down on any pill: move into the active tab's content. The tab bar
    /// doesn't know about that content (`PlayerTopPanelView` does), so this
    /// just reports the request upward.
    var onEnterContent: (() -> Void)?

    private(set) var activeTab: PlayerTopPanelTab
    private var pills: [PlayerTopPanelTab: PlayerInfoPillButton] = [:]
    /// The pill that actually holds focus right now (or last held it),
    /// returned first from `preferredFocusEnvironments` below — mirrors
    /// `PlayerRailView.lastFocusedButton`. Without it, every directional
    /// press that makes the engine fall back to asking an ancestor for its
    /// preference landed back on `pills[activeTab]` — which only updates
    /// AFTER a move completes — so the fallback kept re-proposing the pill
    /// focus was already on, and Left/Right/Down all silently no-opped.
    private weak var lastFocusedPill: PlayerInfoPillButton?
    private let stack = UIStackView()

    init(initialTab: PlayerTopPanelTab) {
        activeTab = initialTab
        super.init(frame: .zero)

        stack.axis = .horizontal
        stack.spacing = Metrics.gap
        stack.alignment = .center
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Below every pill's compression resistance (set below): if the row
        // ever runs out of room, the STACK gives way, not the pills' own
        // text — three legible pills matter more than respecting this
        // trailing margin to the point. Mirrors `PlayerRailPanelView.present`'s
        // own trailing constraint, same reasoning.
        let trailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        trailing.priority = .defaultLow + 250
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
        ])

        for tab in PlayerTopPanelTab.allCases {
            let pill = PlayerInfoPillButton(title: tab.title)
            pill.isSelectedTab = tab == activeTab
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            pill.setContentHuggingPriority(.required, for: .horizontal)
            // Up with nothing above: close the panel, same for every tab
            // (they're all in this one topmost row).
            pill.onUpAtStart = { [weak self] in self?.onCloseRequested?() }
            pill.onLeftRight = { [weak self] forward in self?.moveFocus(from: tab, forward: forward) }
            pill.onDownAtEnd = { [weak self] in self?.onEnterContent?() }
            stack.addArrangedSubview(pill)
            pills[tab] = pill
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedPill, !last.isHidden, last.window != nil { return [last] }
        return pills[activeTab].map { [$0] } ?? []
    }

    /// Returns focus here — the content's Up-at-first-row hook.
    func focusActiveTab() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Explicit Left/Right: step to the neighboring tab (clamped, not
    /// wrapping) and request focus directly, rather than relying on the
    /// focus engine to find it on its own. See the file header.
    private func moveFocus(from tab: PlayerTopPanelTab, forward: Bool) {
        let all = PlayerTopPanelTab.allCases
        guard let index = all.firstIndex(of: tab) else { return }
        let nextIndex = forward ? index + 1 : index - 1
        guard all.indices.contains(nextIndex), let nextPill = pills[all[nextIndex]] else { return }
        lastFocusedPill = nextPill
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView as? PlayerInfoPillButton else { return }
        lastFocusedPill = next
        guard let tab = pills.first(where: { $0.value === next })?.key, tab != activeTab else { return }
        activeTab = tab
        for (t, pill) in pills { pill.isSelectedTab = t == tab }
        PlayerTopPanelTab.lastUsed = tab
        onTabChanged?(tab)
    }
}

// MARK: - PlayerTopPanelView

/// The panel's whole content: the tab bar plus one pre-built content view
/// per tab, shown/hidden rather than swapped in and out — simpler than
/// rebuilding a tab's rows (and their Combine subscriptions) on every
/// switch, and it keeps whatever each tab's `CardTrackListView` already
/// tracks about its own focus.
final class PlayerTopPanelView: UIView {
    /// Wide enough for three comfortably-sized pills ("Subtitles" being the
    /// long one) plus real margin either side — the narrow 450pt popup/menu
    /// width (sized for a single column of choices) left them crushed
    /// against each other and, with the stack's own trailing constraint
    /// required against a too-small bound, produced an unsatisfiable Auto
    /// Layout pass whose resulting frames weren't just visually cramped but
    /// geometrically broken enough to throw off focus navigation too.
    static let width: CGFloat = 720

    private enum Metrics {
        static let tabBarTop: CGFloat = 24
        static let tabBarToContent: CGFloat = 24
        static let sideInset: CGFloat = 35
    }

    /// Which half of the panel `preferredFocusEnvironments` should hand
    /// focus to. Needed because that choice is no longer a static "always
    /// the tab bar" — Down on a pill (`onEnterContent`) needs it to resolve
    /// to the active tab's content instead, explicitly.
    private enum FocusTarget {
        case tabBar
        case content
    }

    private let tabBar: PlayerTopPanelTabBar
    private let contentByTab: [PlayerTopPanelTab: UIView]
    private var focusTarget: FocusTarget = .tabBar

    var onCloseRequested: (() -> Void)? {
        get { tabBar.onCloseRequested }
        set { tabBar.onCloseRequested = newValue }
    }

    init(contentByTab: [PlayerTopPanelTab: UIView]) {
        let initialTab = PlayerTopPanelTab.lastUsed
        tabBar = PlayerTopPanelTabBar(initialTab: initialTab)
        self.contentByTab = contentByTab
        super.init(frame: .zero)

        addSubview(tabBar)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        // Same reasoning as the tab bar's own stack trailing constraint:
        // required-vs-required against a too-small width is how the
        // previous layout broke. At `width` above this never actually
        // binds, but it stays a soft bound rather than a hard one.
        let tabBarTrailing = tabBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.sideInset)
        tabBarTrailing.priority = .defaultLow + 250
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.tabBarTop),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideInset),
            tabBarTrailing,
        ])

        for tab in PlayerTopPanelTab.allCases {
            guard let content = contentByTab[tab] else { continue }
            addSubview(content)
            content.translatesAutoresizingMaskIntoConstraints = false
            content.isHidden = tab != initialTab
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: Metrics.tabBarToContent),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        tabBar.onTabChanged = { [weak self] tab in
            guard let self else { return }
            for (t, view) in self.contentByTab { view.isHidden = t != tab }
        }
        tabBar.onEnterContent = { [weak self] in self?.enterContent() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch focusTarget {
        case .tabBar: return [tabBar]
        case .content: return contentByTab[tabBar.activeTab].map { [$0] } ?? [tabBar]
        }
    }

    /// Exposed so each tab's first control can return focus to the tab bar on Up.
    func focusTabBar() {
        focusTarget = .tabBar
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Down on the tab bar: explicit move into the active tab's content,
    /// same reasoning as `PlayerTopPanelTabBar.moveFocus` — `self` (not
    /// `content` directly) issues the request because `self`, not the
    /// content, is what currently contains focus.
    private func enterContent() {
        focusTarget = .content
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

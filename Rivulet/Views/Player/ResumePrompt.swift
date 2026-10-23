// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ResumePrompt.swift
//  Rivulet
//
//  The one Resume / Start from Beginning decision, shared by every direct
//  play entry point (PlexHomeViewController's tile taps, Continue Watching,
//  hero Play, and PreviewCarouselViewController's detail-page Play, episode
//  lists, season Play). An explicit "Watch from Beginning" action never
//  calls this — it already knows its answer and plays straight through.
//

import UIKit

/// Settings → Playback → "When Resuming". Persisted as a plain string via
/// `SettingsStore`, same mechanism as every other Settings picker.
nonisolated enum ResumeBehavior: String, CaseIterable, CustomStringConvertible {
    case alwaysAsk
    case alwaysResume
    case alwaysStartOver

    static let storageKey = "resumeBehavior"

    @MainActor
    static var current: ResumeBehavior {
        ResumeBehavior(rawValue: SettingsStore.string(storageKey, default: ResumeBehavior.alwaysAsk.rawValue)) ?? .alwaysAsk
    }

    var description: String {
        switch self {
        case .alwaysAsk: "Always Ask"
        case .alwaysResume: "Always Resume"
        case .alwaysStartOver: "Always Start Over"
        }
    }
}

enum ResumePrompt {
    /// Below this, a resume point isn't worth interrupting Play for — a few
    /// seconds of an accidental start. Deliberately NOT `WatchProgressPolicy`
    /// (its 2% floor and 90% ceiling are tuned for progress bars, On Deck and
    /// "has this been watched" display, not this decision): this is a flat,
    /// low floor on the raw saved position, nothing else — see `resolve`'s
    /// doc comment for why watched status plays no part here either.
    static let minimumOffsetSeconds: TimeInterval = 10

    /// Decide what Play should do for an item that MIGHT have a resume
    /// point, consulting `ResumeBehavior`. When the decision needs asking,
    /// `onDecision` runs once per answer and NOT AT ALL on cancel (Menu/Back)
    /// — that's the whole point of "cancel without playing": the caller never
    /// acts, Play behaves as if never pressed. When no asking is needed,
    /// `onDecision` runs synchronously-equivalent with `fromBeginning: false`
    /// (resume, or just play normally when there was nothing to resume).
    ///
    /// Gates on the raw saved position alone — more than `minimumOffsetSeconds`
    /// is enough, regardless of `isWatched`/`viewCount`. Plex keeps a real
    /// `viewOffset` on an already-watched title once a rewatch is stopped
    /// partway through (the same fact `PlexMetadata.isWatched` and
    /// `MediaUserState.isInProgress` work around elsewhere — see CLAUDE.md's
    /// "resume point outranks the watched flag", issue #270), so excluding
    /// watched items here would silently skip the prompt for exactly the
    /// stopped-rewatch case it needs to cover.
    @MainActor
    static func resolve(
        offsetSeconds: TimeInterval,
        from viewController: UIViewController,
        onDecision: @escaping (_ fromBeginning: Bool) -> Void
    ) {
        guard offsetSeconds > minimumOffsetSeconds else {
            onDecision(false)
            return
        }
        switch ResumeBehavior.current {
        case .alwaysResume: onDecision(false)
        case .alwaysStartOver: onDecision(true)
        case .alwaysAsk: present(offsetSeconds: offsetSeconds, from: viewController, onDecision: onDecision)
        }
    }

    /// A custom popup, not `UIAlertController`: tvOS only dismisses an
    /// actionSheet on Menu when it holds a `.cancel`-style action, and in
    /// this app that style always renders as its own visible row (confirmed
    /// against the existing Sort/Type pickers) — a third button, which isn't
    /// the two-button dialog this asks for. `ResumePromptPopupViewController`
    /// owns Menu itself via a `.menu`-typed tap recognizer instead, the same
    /// mechanism `TileMenuPopupViewController` already uses for exactly this
    /// reason.
    @MainActor
    private static func present(
        offsetSeconds: TimeInterval,
        from viewController: UIViewController,
        onDecision: @escaping (Bool) -> Void
    ) {
        let offsetMs = Int(offsetSeconds * 1000)
        let popup = ResumePromptPopupViewController(
            resumeTitle: "Resume Playing (\(PlexMetadata.formatResumeTime(offsetMs)))",
            onDecision: onDecision
        )
        viewController.present(popup, animated: false)
    }
}

// MARK: - Popup

/// Two stacked capsule rows on a glass panel, centered on screen (no tile to
/// grow from — this fires from many different surfaces). Resume is first, so
/// it holds initial focus. Visual recipe matches `WatchlistGenreFilterPopupViewController`'s
/// `GenreFilterRow` (white-focused / translucent-unfocused capsule) minus the
/// checkmark — these rows aren't toggles, they're one-shot choices.
private final class ResumePromptPopupViewController: UIViewController {

    private let resumeTitle: String
    private let onDecision: (Bool) -> Void

    private var panel: UIVisualEffectView!
    private var resumeRow: ResumePromptRow!
    private var isDismissing = false

    private enum Metrics {
        static let panelWidth: CGFloat = 560
        static let panelInset: CGFloat = 20
        static let rowHeight: CGFloat = 68
        static let rowSpacing: CGFloat = 10
    }

    init(resumeTitle: String, onDecision: @escaping (Bool) -> Void) {
        self.resumeTitle = resumeTitle
        self.onDecision = onDecision
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let dimColor = UIColor.black.withAlphaComponent(0.55)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        resumeRow = ResumePromptRow(title: resumeTitle)
        resumeRow.onSelect = { [weak self] in self?.finish(fromBeginning: false) }
        let startOverRow = ResumePromptRow(title: "Start from Beginning")
        startOverRow.onSelect = { [weak self] in self?.finish(fromBeginning: true) }

        let stack = UIStackView(arrangedSubviews: [resumeRow, startOverRow])
        stack.axis = .vertical
        stack.spacing = Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        panel = UIVisualEffectView(effect: effect)
        panel.layer.cornerRadius = 32
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.contentView.addSubview(stack)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let panelHeight = Metrics.panelInset * 2 + Metrics.rowHeight * 2 + Metrics.rowSpacing
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: Metrics.panelInset),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: Metrics.panelInset),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -Metrics.panelInset),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -Metrics.panelInset),

            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: Metrics.panelWidth),
            panel.heightAnchor.constraint(equalToConstant: panelHeight),
        ])

        // Entrance start state; animated in viewDidAppear (mirrors
        // TileMenuPopupViewController's two-clock grow + fade).
        panel.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        panel.alpha = 0

        // Owns Menu directly — see this type's doc comment for why Menu
        // can't just dismiss a plain UIAlertController here. No decision
        // fires: that's "cancel without playing".
        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    @objc private func menuPressed() { animateOut(completion: nil) }

    private func finish(fromBeginning: Bool) {
        guard !isDismissing else { return }
        animateOut { [weak self] in self?.onDecision(fromBeginning) }
    }

    private func animateOut(completion: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        let exit = UIViewPropertyAnimator(duration: 0.18, curve: .easeIn) {
            self.panel.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            self.panel.alpha = 0
            self.view.backgroundColor = .clear
        }
        exit.addCompletion { _ in self.dismiss(animated: false) { completion?() } }
        exit.startAnimation()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [resumeRow].compactMap { $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let entrance = UIViewPropertyAnimator(duration: 0.3, dampingRatio: 0.85) {
            self.panel.transform = .identity
            self.view.backgroundColor = self.dimColor
        }
        UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) {
            self.panel.alpha = 1
        }.startAnimation()
        entrance.startAnimation()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

/// One focusable capsule row: bold centered title, white-focused /
/// translucent-unfocused, no checkmark (these are one-shot choices, not
/// toggles). Visual recipe shared with `GenreFilterRow`
/// (`WatchlistGenreFilterPopupViewController.swift`).
private final class ResumePromptRow: UIView {

    static let height: CGFloat = 68

    private let bg = CapsuleBackgroundView()
    private let titleLabel = UILabel()

    var onSelect: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.isUserInteractionEnabled = false
        addSubview(bg)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(titleLabel)

        applyUnfocusedAppearance()

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -24),
            titleLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onSelect?() }

    private func applyUnfocusedAppearance() {
        bg.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        titleLabel.textColor = .white
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            if focused {
                self.bg.backgroundColor = .white
                self.titleLabel.textColor = .black
            } else {
                self.applyUnfocusedAppearance()
            }
        }
    }
}

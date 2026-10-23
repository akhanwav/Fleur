// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchlistGenreFilterPopupViewController.swift
//  Rivulet
//
//  Multi-select Genre filter for the Watchlist grid. A glass popup grown
//  from the header's Genre button (same chrome recipe as
//  TileMenuPopupViewController's tile long-press menu: glass platter,
//  dimmed backdrop, grow/shrink-from-corner animation, Menu press), but the
//  rows TOGGLE instead of dismissing: Select flips a genre's checkmark, the
//  live count updates, and the selection only applies on Done or Menu —
//  both close AND apply (there is no Cancel, matching how every other
//  Watchlist picker keeps the last choice made). Row look (trailing
//  blue/black checkmark on a white-when-focused capsule) matches
//  `SettingsCell`'s checkmark rows, the app's other multi-state picker row.
//

import UIKit

final class WatchlistGenreFilterPopupViewController: UIViewController {

    private let genres: [String]
    private var selected: Set<String>
    private let sourceFrame: CGRect?
    /// Recomputes the live "N titles" count for a candidate selection —
    /// same AND-across-the-set rule `PlexHomeViewController.watchlistItems(matchingType:genres:from:)`
    /// applies to the grid itself.
    private let countProvider: (Set<String>) -> Int
    private let onApply: (Set<String>) -> Void

    private var panel: UIVisualEffectView!
    private var countLabel: UILabel!
    private var rows: [GenreFilterRow] = []
    private var clearAllRow: GenreFilterRow!
    private var doneButton: SortButton!
    private var isDismissing = false

    private enum Metrics {
        static let panelWidth: CGFloat = 460
        static let panelInset: CGFloat = 28
        static let rowSpacing: CGFloat = 8
        static let maxScrollHeight: CGFloat = 424  // ~6 rows before it scrolls
        static let headerSpacing: CGFloat = 18
        static let footerSpacing: CGFloat = 20
        static let doneWidth: CGFloat = 180
        static let doneHeight: CGFloat = 56
    }

    /// Present with `animated: false` — entrance/exit run in-controller so
    /// the panel can grow from / shrink to the Genre button's corner.
    init(genres: [String], selected: Set<String>, sourceFrame: CGRect?,
         countProvider: @escaping (Set<String>) -> Int,
         onApply: @escaping (Set<String>) -> Void) {
        self.genres = genres
        self.selected = selected
        self.sourceFrame = sourceFrame
        self.countProvider = countProvider
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let dimColor = UIColor.black.withAlphaComponent(0.55)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let titleLabel = UILabel()
        titleLabel.text = "Genre"
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .white

        countLabel = UILabel()
        countLabel.font = .systemFont(ofSize: 20, weight: .medium)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        clearAllRow = GenreFilterRow(title: "Clear All", isClearAll: true)
        clearAllRow.onSelect = { [weak self] in self?.clearAll() }

        rows = genres.map { genre in
            let row = GenreFilterRow(title: genre)
            row.isChecked = selected.contains(genre)
            row.onSelect = { [weak self] in self?.toggle(genre) }
            return row
        }

        let rowsStack = UIStackView(arrangedSubviews: [clearAllRow] + rows)
        rowsStack.axis = .vertical
        rowsStack.spacing = Metrics.rowSpacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        doneButton = SortButton()
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.configure(sortName: "Done", symbol: "checkmark")
        doneButton.onSortTapped = { [weak self] in self?.finish() }

        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        panel = UIVisualEffectView(effect: effect)
        panel.layer.cornerRadius = 38
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        [headerStack, scrollView, doneButton].forEach { panel.contentView.addSubview($0) }

        // Row count determines the scroll area's actual height, clamped —
        // a short genre list gets a compact panel with no dead space; a
        // long one scrolls within the cap.
        let rowCount = rows.count + 1
        let fullRowsHeight = CGFloat(rowCount) * GenreFilterRow.height
            + CGFloat(rowCount - 1) * Metrics.rowSpacing
        let scrollHeight = min(fullRowsHeight, Metrics.maxScrollHeight)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: Metrics.panelInset),
            headerStack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: Metrics.panelInset),
            headerStack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -Metrics.panelInset),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: Metrics.headerSpacing),
            scrollView.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: Metrics.panelInset),
            scrollView.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -Metrics.panelInset),
            scrollView.heightAnchor.constraint(equalToConstant: scrollHeight),

            doneButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Metrics.footerSpacing),
            doneButton.centerXAnchor.constraint(equalTo: panel.contentView.centerXAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: Metrics.doneWidth),
            doneButton.heightAnchor.constraint(equalToConstant: Metrics.doneHeight),
            doneButton.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -Metrics.panelInset),
        ])

        updateCount()

        let headerHeight = ceil(headerStack.systemLayoutSizeFitting(
            CGSize(width: Metrics.panelWidth - Metrics.panelInset * 2, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        let totalHeight = Metrics.panelInset * 2 + headerHeight + Metrics.headerSpacing
            + scrollHeight + Metrics.footerSpacing + Metrics.doneHeight

        // Drops below the Genre button, right-aligned to its trailing edge
        // (it sits at the header's right edge) — falls back to left-aligned
        // only if that would run past the safe area.
        let safe = view.bounds.insetBy(dx: 80, dy: 50)
        let gap: CGFloat = 16
        var origin: CGPoint
        var growsFromRightEdge = true
        if let sourceFrame {
            origin = CGPoint(x: sourceFrame.maxX - Metrics.panelWidth, y: sourceFrame.maxY + gap)
            if origin.x < safe.minX {
                origin.x = sourceFrame.minX
                growsFromRightEdge = false
            }
        } else {
            origin = CGPoint(x: view.bounds.midX - Metrics.panelWidth / 2, y: view.bounds.midY - totalHeight / 2)
        }
        origin.x = min(max(origin.x, safe.minX), safe.maxX - Metrics.panelWidth)
        origin.y = min(max(origin.y, safe.minY), safe.maxY - totalHeight)
        panel.frame = CGRect(origin: origin, size: CGSize(width: Metrics.panelWidth, height: totalHeight))
        view.addSubview(panel)

        let anchor = CGPoint(x: growsFromRightEdge ? 1 : 0, y: 0)
        let frame = panel.frame
        panel.layer.anchorPoint = anchor
        panel.layer.position = CGPoint(x: frame.minX + frame.width * anchor.x,
                                       y: frame.minY + frame.height * anchor.y)

        panel.transform = CGAffineTransform(scaleX: 0.02, y: 0.02)
        panel.alpha = 0

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    private func toggle(_ genre: String) {
        if selected.contains(genre) { selected.remove(genre) } else { selected.insert(genre) }
        rows.first(where: { $0.title == genre })?.isChecked = selected.contains(genre)
        updateCount()
    }

    private func clearAll() {
        guard !selected.isEmpty else { return }
        selected.removeAll()
        rows.forEach { $0.isChecked = false }
        updateCount()
    }

    private func updateCount() {
        let count = countProvider(selected)
        countLabel.text = count == 1 ? "1 title" : "\(count) titles"
    }

    /// Menu applies the in-progress selection exactly like Done — there is
    /// no cancel/discard path here (see the init's doc comment).
    @objc private func menuPressed() { finish() }

    private func finish() {
        guard !isDismissing else { return }
        isDismissing = true
        onApply(selected)
        let exit = UIViewPropertyAnimator(duration: 0.22, curve: .easeIn) {
            self.panel.transform = CGAffineTransform(scaleX: 0.02, y: 0.02)
            self.panel.alpha = 0
            self.view.backgroundColor = .clear
        }
        exit.addCompletion { _ in self.dismiss(animated: false) }
        exit.startAnimation()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [clearAllRow].compactMap { $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let entrance = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.82) {
            self.panel.transform = .identity
            self.view.backgroundColor = self.dimColor
        }
        UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) {
            self.panel.alpha = 1
        }.startAnimation()
        entrance.startAnimation()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

// MARK: - Checkable row

/// A focusable capsule row with a trailing checkmark that TOGGLES on Select
/// instead of dismissing anything — the multi-select counterpart of
/// `TileMenuPopupViewController`'s `MenuRowButton`. Visual recipe matches
/// `SettingsCell`'s checkmark rows (white-focused capsule, dark content;
/// translucent glass unfocused, white content, blue checkmark).
private final class GenreFilterRow: UIView {

    static let height: CGFloat = 64

    let title: String
    private let isClearAll: Bool
    private let bg = CapsuleBackgroundView()
    private let titleLabel = UILabel()
    private let checkmark = UIImageView()

    var onSelect: (() -> Void)?

    var isChecked: Bool = false {
        didSet { checkmark.isHidden = isClearAll || !isChecked }
    }

    override var canBecomeFocused: Bool { true }

    init(title: String, isClearAll: Bool = false) {
        self.title = title
        self.isClearAll = isClearAll
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.isUserInteractionEnabled = false
        addSubview(bg)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(titleLabel)

        checkmark.image = UIImage(systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(checkmark)

        applyUnfocusedAppearance()

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 28),
            titleLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -12),

            checkmark.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -26),
            checkmark.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onSelect?() }

    private func applyUnfocusedAppearance() {
        bg.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        titleLabel.textColor = .white
        checkmark.tintColor = .systemBlue
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            if focused {
                self.bg.backgroundColor = .white
                self.titleLabel.textColor = .black
                self.checkmark.tintColor = .black
            } else {
                self.applyUnfocusedAppearance()
            }
        }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchlistFilterHeaderCell.swift
//  Rivulet
//
//  Full-width header cell for the Watchlist grid (PlexHomeViewController's
//  `.watchlist` mode): title + filtered item count on the left, three
//  focusable glass buttons on the right (Sort / Type / Genre). Sibling of
//  `MediaLibrarySortControl` — same glass button (`SortButton`, defined
//  there), same non-focusable cell forwarding focus to its buttons — but
//  simpler: all three buttons are always visible, no Titles/Collections-style
//  conditional swap. The person page's filmography reuses it with a fourth,
//  an On My Servers toggle (`configure(toggle:)`).
//

import UIKit

final class WatchlistFilterHeaderControl: UICollectionViewCell {

    static let reuseID = "watchlist.filterHeader"

    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 34, weight: .bold)
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let countLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 17)
        lb.textColor = UIColor.white.withAlphaComponent(0.5)
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let sortButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let typeButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let genreButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// Optional trailing toggle; hidden unless `configure` names one.
    private let toggleButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()

    private let buttonsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    var onSortTapped: (() -> Void)? {
        get { sortButton.onSortTapped }
        set { sortButton.onSortTapped = newValue }
    }

    var onTypeTapped: (() -> Void)? {
        get { typeButton.onSortTapped }
        set { typeButton.onSortTapped = newValue }
    }

    var onGenreTapped: (() -> Void)? {
        get { genreButton.onSortTapped }
        set { genreButton.onSortTapped = newValue }
    }

    var onToggleTapped: (() -> Void)? {
        get { toggleButton.onSortTapped }
        set { toggleButton.onSortTapped = newValue }
    }

    /// For anchoring the multi-select Genre popup beside this button —
    /// see `WatchlistGenreFilterPopupViewController`.
    var genreButtonView: UIView { genreButton }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Cell must NOT be focusable; only the buttons are.
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(buttonsStack)
        // Right-anchored row: Sort, Type, Genre, then the toggle when shown.
        // A hidden arranged view takes no space, so the Watchlist's three
        // still end on the trailing edge.
        [sortButton, typeButton, genreButton, toggleButton].forEach(buttonsStack.addArrangedSubview)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            buttonsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            buttonsStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            buttonsStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),

            sortButton.heightAnchor.constraint(equalToConstant: 44),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            typeButton.heightAnchor.constraint(equalToConstant: 44),
            typeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            genreButton.heightAnchor.constraint(equalToConstant: 44),
            genreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            toggleButton.heightAnchor.constraint(equalToConstant: 44),
            toggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    /// `toggle` adds the trailing On/Off button (its title, and whether it
    /// is on); nil leaves the three Watchlist buttons alone.
    func configure(title: String, count: Int, sortName: String, typeName: String, genreName: String,
                   countNoun: (one: String, many: String) = ("item", "items"),
                   toggle: (title: String, isOn: Bool)? = nil) {
        titleLabel.text = title
        countLabel.text = count == 1 ? "1 \(countNoun.one)" : "\(count) \(countNoun.many)"
        sortButton.configure(sortName: sortName, symbol: "arrow.up.arrow.down")
        typeButton.configure(sortName: typeName, symbol: "line.3.horizontal.decrease.circle")
        genreButton.configure(sortName: genreName, symbol: "theatermasks")
        toggleButton.isHidden = toggle == nil
        if let toggle {
            toggleButton.configure(sortName: toggle.title,
                                   symbol: toggle.isOn ? "checkmark.circle.fill" : "circle")
        }
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton, typeButton, genreButton, toggleButton].filter { !$0.isHidden }
    }
}

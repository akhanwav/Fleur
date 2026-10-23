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
//  conditional swap.
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        // Cell must NOT be focusable; only the three buttons are.
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(sortButton)
        contentView.addSubview(typeButton)
        contentView.addSubview(genreButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            // Right-anchored chain: Genre at the trailing edge, Type left of
            // it, Sort left of that. All three always visible (unlike the
            // library header's Titles/Collections swap).
            genreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            genreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            genreButton.heightAnchor.constraint(equalToConstant: 44),
            genreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            typeButton.trailingAnchor.constraint(equalTo: genreButton.leadingAnchor, constant: -16),
            typeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            typeButton.heightAnchor.constraint(equalToConstant: 44),
            typeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            sortButton.trailingAnchor.constraint(equalTo: typeButton.leadingAnchor, constant: -16),
            sortButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sortButton.heightAnchor.constraint(equalToConstant: 44),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            sortButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])
    }

    func configure(title: String, count: Int, sortName: String, typeName: String, genreName: String) {
        titleLabel.text = title
        countLabel.text = count == 1 ? "1 item" : "\(count) items"
        sortButton.configure(sortName: sortName, symbol: "arrow.up.arrow.down")
        typeButton.configure(sortName: typeName, symbol: "line.3.horizontal.decrease.circle")
        genreButton.configure(sortName: genreName, symbol: "theatermasks")
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton, typeButton, genreButton]
    }
}

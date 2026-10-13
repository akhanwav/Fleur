// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PosterSkeletonCell.swift
//  Rivulet
//
//  Loading-placeholder cell for the end of a paginating hub row, in both
//  poster (portrait + title placeholder rows) and Continue Watching
//  (landscape) variants. The placeholder rests where the tile's artwork does.
//
//  Two sizing modes are supported via `configure(isContinueWatching:)`:
//   - false: portrait poster + two title placeholder rows
//   - true:  wide landscape card, no title rows
//

import UIKit

@MainActor
final class PosterSkeletonCell: UICollectionViewCell {
    static let reuseID = "PosterSkeletonCell"

    enum Layout {
        case poster
        case music
        case continueWatching
    }

    private let posterPlaceholder = UIView()
    private let titleRow1 = UIView()
    private let titleRow2 = UIView()
    private let stack = UIStackView()

    private var posterWidthConstraint: NSLayoutConstraint!
    private var posterHeightConstraint: NSLayoutConstraint!
    private var stackTopConstraint: NSLayoutConstraint!
    private var stackLeadingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        let cornerRadius: CGFloat = 16
        posterPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        posterPlaceholder.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        posterPlaceholder.layer.cornerRadius = cornerRadius
        posterPlaceholder.layer.cornerCurve = .continuous

        titleRow1.translatesAutoresizingMaskIntoConstraints = false
        titleRow1.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        titleRow1.layer.cornerRadius = 4
        titleRow1.layer.cornerCurve = .continuous

        titleRow2.translatesAutoresizingMaskIntoConstraints = false
        titleRow2.backgroundColor = UIColor.white.withAlphaComponent(0.04)
        titleRow2.layer.cornerRadius = 4
        titleRow2.layer.cornerCurve = .continuous

        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(posterPlaceholder)
        let titleStack = UIStackView(arrangedSubviews: [titleRow1, titleRow2])
        titleStack.axis = .vertical
        titleStack.spacing = 6
        titleStack.alignment = .leading
        stack.addArrangedSubview(titleStack)

        contentView.addSubview(stack)

        posterWidthConstraint = posterPlaceholder.widthAnchor.constraint(equalToConstant: 0)
        posterHeightConstraint = posterPlaceholder.heightAnchor.constraint(equalToConstant: 0)
        stackTopConstraint = stack.topAnchor.constraint(equalTo: contentView.topAnchor)
        stackLeadingConstraint = stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)

        NSLayoutConstraint.activate([
            stackTopConstraint,
            stackLeadingConstraint,

            posterWidthConstraint,
            posterHeightConstraint,

            titleRow1.widthAnchor.constraint(equalToConstant: 160),
            titleRow1.heightAnchor.constraint(equalToConstant: 14),
            titleRow2.widthAnchor.constraint(equalToConstant: 100),
            titleRow2.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    func configure(layout: Layout) {
        let tile: MediaRowMetrics.Tile
        switch layout {
        case .poster: tile = MediaRowMetrics.poster
        case .music: tile = MediaRowMetrics.music
        case .continueWatching: tile = MediaRowMetrics.continueWatching
        }
        posterWidthConstraint.constant = tile.art.width
        posterHeightConstraint.constant = tile.art.height
        stackLeadingConstraint.constant = (tile.frame.width - tile.art.width) / 2
        stackTopConstraint.constant = (tile.frame.height - tile.art.height) / 2
        titleRow1.isHidden = layout == .continueWatching
        titleRow2.isHidden = layout == .continueWatching
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ViewAllTileCell.swift
//  Rivulet
//
//  The tile at the end of a capped row (`RowCap`): a glass card the size of
//  the row's poster artwork, resting where a poster's does and growing into
//  the frame on focus as a poster does. Selecting it opens the row's View All
//  grid.
//

import UIKit

@MainActor
final class ViewAllTileCell: UICollectionViewCell {
    static let reuseID = "ViewAllTileCell"

    private let card = UIView()
    private let symbol = UIImageView(image: UIImage(systemName: "square.grid.3x3.fill"))
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tile = MediaRowMetrics.poster
        card.frame = CGRect(x: (tile.frame.width - tile.art.width) / 2,
                            y: (tile.frame.height - tile.art.height) / 2,
                            width: tile.art.width, height: tile.art.height)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        contentView.addSubview(card)

        symbol.tintColor = .white
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        label.text = "View All"
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        let stack = UIStackView(arrangedSubviews: [symbol, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        applyLook(focused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyLook(focused: Bool) {
        card.backgroundColor = UIColor.white.withAlphaComponent(focused ? 0.22 : 0.08)
        card.layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.35 : 0.1).cgColor
        let tile = MediaRowMetrics.poster
        let scale = focused ? tile.frame.height / tile.art.height : 1
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        label.alpha = focused ? 1 : 0.7
        symbol.alpha = focused ? 1 : 0.7
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard focused || context.previouslyFocusedView === self else { return }
        coordinator.addCoordinatedAnimations({ self.applyLook(focused: focused) }, completion: nil)
    }
}

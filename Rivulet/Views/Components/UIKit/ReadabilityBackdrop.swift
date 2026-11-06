// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ReadabilityBackdrop.swift
//  Rivulet
//
//  A soft dark panel behind a block of text that sits over artwork, so it
//  stays readable over a bright backdrop. It follows the text's frame from
//  outside the layout: the text keeps its position, and the panel reaches a
//  little past it on every side.
//

import UIKit

final class ReadabilityBackdrop: UIView {
    private static let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts the panel behind `text`, in `container` (an ancestor of `text`),
    /// below everything else there.
    func attach(behind text: UIView, in container: UIView) {
        container.insertSubview(self, at: 0)
        let i = Self.inset
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: text.topAnchor, constant: -i.top),
            bottomAnchor.constraint(equalTo: text.bottomAnchor, constant: i.bottom),
            leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: -i.left),
            trailingAnchor.constraint(equalTo: text.trailingAnchor, constant: i.right),
        ])
    }
}

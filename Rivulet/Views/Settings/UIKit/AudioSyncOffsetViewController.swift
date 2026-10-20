// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AudioSyncOffsetViewController.swift
//  Rivulet
//
//  Settings' global Audio Sync default. Same glass-card shell as
//  TextEntryViewController, holding one CardStepperRowView — the exact
//  control the player's own Audio panel uses for its per-title delta — bound
//  here to AudioSyncAdjustments.globalDefaultMs instead.
//

import UIKit

@MainActor
final class AudioSyncOffsetViewController: UIViewController {

    /// Called after every step, so the Settings row behind this modal shows
    /// the new value without waiting for dismiss.
    private let onChange: () -> Void
    private var stepperRow: CardStepperRowView!

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Same card chrome as TextEntryViewController / the confirm popups,
        // so every modal reads as one family.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let effect: UIVisualEffect
        if #available(tvOS 26.0, *) { effect = UIGlassEffect() }
        else { effect = UIBlurEffect(style: .regular) }
        let blur = UIVisualEffectView(effect: effect)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 38
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        card.addSubview(blur)

        let titleLabel = UILabel()
        titleLabel.text = "Audio Sync"
        titleLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        titleLabel.textAlignment = .center

        let hintLabel = UILabel()
        hintLabel.text = "Applied to every title, on top of any per-title adjustment made from the player's Audio menu."
        hintLabel.font = .systemFont(ofSize: 24, weight: .regular)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        let row = CardStepperRowView(config: CardStepperConfig(
            title: "Offset",
            value: { AudioSyncAdjustments.formatted(AudioSyncAdjustments.globalDefaultMs) },
            onStep: { [weak self] step in
                AudioSyncAdjustments.setGlobalDefaultMs(
                    AudioSyncAdjustments.globalDefaultMs + step * AudioSyncAdjustments.stepMs)
                self?.onChange()
            }))
        stepperRow = row

        let doneButton = TextEntryPillButton(title: "Done", prominent: true) { [weak self] in
            self?.dismiss(animated: true)
        }

        let stack = UIStackView(arrangedSubviews: [titleLabel, hintLabel, row, doneButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 28
        stack.setCustomSpacing(36, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        let pad: CGFloat = 52
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 700),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),

            doneButton.heightAnchor.constraint(equalToConstant: 72),
        ])

        // Menu dismisses, same as TextEntryViewController.
        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    // The stepper's `+` button takes initial focus — adjusting it is the
    // whole point of this modal, same reasoning as the text field in
    // TextEntryViewController.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [stepperRow.incrementButton]
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func menuPressed() {
        dismiss(animated: true)
    }
}

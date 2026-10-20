// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TextEntryViewController.swift
//  Rivulet
//
//  UIKit text entry for the settings pages. A centered frosted Liquid-Glass
//  card holding a `UITextField` (system tvOS keyboard) plus optional suggestion
//  pills, in the same chrome family as `ConfirmationPopupViewController` /
//  `InfoPopupViewController`.
//
//  Commit vs cancel is explicit: Done (or keyboard submit) calls `onCommit`
//  with the final text; Menu / Cancel calls `onCancel` and leaves the caller's
//  value untouched. The caller only ever writes on commit.
//
//  tvOS focus: the text field takes initial focus in `viewDidAppear` (the view
//  must be in the window — an earlier request is a no-op). Suggestion pills own
//  Select via a press-typed tap recognizer, since a bare control's
//  primaryAction does NOT fire on Select.
//

import UIKit

@MainActor
final class TextEntryViewController: UIViewController {

    /// Label + value pair for a suggestion pill.
    typealias Suggestion = (label: String, value: String)

    private let titleText: String
    private let initialText: String
    private let placeholder: String
    private let hint: String?
    private let suggestions: [Suggestion]
    private let keyboard: UIKeyboardType
    private let isSecure: Bool

    /// Final text, on Done / keyboard submit only. Never called on cancel.
    private let onCommit: (String) -> Void
    /// Menu / Cancel — the caller leaves its value unchanged.
    private let onCancel: (() -> Void)?

    private let textField = UITextField()
    private var doneButton: TextEntryPillButton!
    private var cancelButton: TextEntryPillButton!

    init(title: String,
         initialText: String,
         placeholder: String = "",
         hint: String? = nil,
         suggestions: [Suggestion] = [],
         keyboardType: UIKeyboardType = .default,
         isSecure: Bool = false,
         onCommit: @escaping (String) -> Void,
         onCancel: (() -> Void)? = nil) {
        self.titleText = title
        self.initialText = initialText
        self.placeholder = placeholder
        self.hint = hint
        self.suggestions = suggestions
        self.keyboard = keyboardType
        self.isSecure = isSecure
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        // Same card chrome as the confirm/info popups so every modal reads as
        // one family. (tvOS UIBlurEffect has no systemMaterial styles.)
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
        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        titleLabel.textAlignment = .center

        textField.text = initialText
        textField.placeholder = placeholder
        textField.font = .systemFont(ofSize: 36, weight: .regular)
        textField.textColor = .white
        textField.keyboardType = keyboard
        textField.autocorrectionType = .no
        // Only prose gets a capital: not an address, a username, or a password.
        textField.autocapitalizationType = (keyboard == .default) ? .sentences : .none
        textField.isSecureTextEntry = isSecure
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .done
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        var fieldStack: [UIView] = [titleLabel, textField]

        if let hint {
            let hintLabel = UILabel()
            hintLabel.text = hint
            hintLabel.font = .systemFont(ofSize: 24, weight: .regular)
            hintLabel.textColor = UIColor.white.withAlphaComponent(0.45)
            hintLabel.textAlignment = .center
            hintLabel.numberOfLines = 0
            fieldStack.append(hintLabel)
        }

        let stack = UIStackView(arrangedSubviews: fieldStack)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 20

        // Suggestions: a focusable pill per preset, filling the field on Select.
        if !suggestions.isEmpty {
            let pills = suggestions.map { suggestion in
                TextEntryPillButton(title: suggestion.label, prominent: false) { [weak self] in
                    self?.textField.text = suggestion.value
                }
            }
            let pillRow = UIStackView(arrangedSubviews: pills)
            pillRow.axis = .horizontal
            pillRow.alignment = .center
            pillRow.distribution = .fillProportionally
            pillRow.spacing = 16
            // Gap between the field block and the suggestion row.
            stack.setCustomSpacing(36, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
            stack.addArrangedSubview(pillRow)
            pillRow.heightAnchor.constraint(equalToConstant: 64).isActive = true
        }

        cancelButton = TextEntryPillButton(title: "Cancel", prominent: false) { [weak self] in
            self?.cancel()
        }
        doneButton = TextEntryPillButton(title: "Done", prominent: true) { [weak self] in
            self?.commit()
        }
        let buttonRow = UIStackView(arrangedSubviews: [cancelButton, doneButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 24

        stack.setCustomSpacing(36, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        stack.addArrangedSubview(buttonRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        let pad: CGFloat = 52
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 1000),

            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),

            textField.heightAnchor.constraint(equalToConstant: 76),
            buttonRow.heightAnchor.constraint(equalToConstant: 72)
        ])

        // Menu cancels (the pills own Select via their own recognizers).
        let menuTap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    // The field takes initial focus; on tvOS focusing it opens the system
    // keyboard. Must run once the view is in the window — an earlier request
    // is a no-op.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [textField]
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func menuPressed() { cancel() }

    private func commit() {
        let value = textField.text ?? ""
        dismiss(animated: true) { [onCommit] in onCommit(value) }
    }

    private func cancel() {
        dismiss(animated: true) { [onCancel] in onCancel?() }
    }
}

extension TextEntryViewController: UITextFieldDelegate {
    // Keyboard "Done" commits.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commit()
        return true
    }
}

// MARK: - Focusable pill button

/// Focusable pill matching the confirm-popup vocabulary: bright white + dark
/// text on focus, translucent glass otherwise. Owns Select via a press-typed
/// tap recognizer, since a bare control's primaryAction doesn't fire on tvOS.
/// Not file-private: `AudioSyncOffsetViewController` reuses it for its own
/// Done button, in the same glass-card modal family.
final class TextEntryPillButton: UIView {

    private let labelView = UILabel()
    private let onPress: () -> Void
    private let prominent: Bool

    override var canBecomeFocused: Bool { true }

    init(title: String, prominent: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.prominent = prominent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 30
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        applyUnfocusedStyle()

        labelView.text = title
        labelView.font = .systemFont(ofSize: 26, weight: prominent ? .semibold : .medium)
        labelView.textColor = .white
        labelView.textAlignment = .center
        labelView.lineBreakMode = .byTruncatingTail
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)
        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            labelView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress() }

    private func applyUnfocusedStyle() {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            if focused {
                self.backgroundColor = .white
                self.labelView.textColor = .black
                self.layer.borderColor = UIColor.clear.cgColor
                self.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            } else {
                self.applyUnfocusedStyle()
                self.labelView.textColor = .white
                self.transform = .identity
            }
        })
    }
}

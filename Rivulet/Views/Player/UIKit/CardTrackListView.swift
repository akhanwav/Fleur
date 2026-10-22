// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import Combine

// MARK: - CardTrackListView

/// A choice menu in the rail's glass popup, cloned from AVKit's tvOS 26 tool
/// menus (`AVUnifiedPlayerContextMenuViewController`). Metrics were read from
/// AVKit's live view tree (DEBUG `AVKitScrubProbe`, RIVULET_SCRUBPROBE=menus):
/// a 70pt section header, 66pt rows (86 with a second line), a checkmark column,
/// and a focused row that turns into a white pill. Fills the popup edge to edge;
/// its own insets match AVKit's.
final class CardTrackListView: UIView {

    /// AVKit's menus are a fixed 450pt wide.
    static let menuWidth: CGFloat = 450

    fileprivate enum Metrics {
        static let headerHeight: CGFloat = 70
        static let headerLabelCenterY: CGFloat = 39.5
        static let headerLabelLeading: CGFloat = 35
        static let rowInset: CGFloat = 21
        static let bottomInset: CGFloat = 18
        static let separatorInset: CGFloat = 15
        static let separatorGap: CGFloat = 18
        static let rowHeight: CGFloat = 66
        static let twoLineRowHeight: CGFloat = 86
        static let checkColumnX: CGFloat = 21
        static let checkColumnWidth: CGFloat = 32
        static let titleX: CGFloat = 69
        static let rowRadius: CGFloat = 33
        /// Focused rows grow 4pt each side, and their content scales to match.
        static let focusGrowth: CGFloat = 4
        static let focusScale: CGFloat = 416 / 408
        static let titleFont = UIFont.systemFont(ofSize: 25, weight: .medium)
        static let secondaryFont = UIFont.systemFont(ofSize: 23, weight: .medium)
        /// AVKit draws secondary text white 0.5 and rules white 0.3 plus-lighter over
        /// its glass; these normal-blend alphas land on the same pixels over it.
        static let secondaryColor = UIColor.white.withAlphaComponent(0.8)
        static let separatorColor = UIColor.white.withAlphaComponent(0.46)
    }

    struct Row {
        let title: String
        let subtitle: String?
        let trackId: Int?
        let isSelected: Bool
    }

    private let rows: [Row]
    private let actions: [CardActionConfig]
    private let toggles: [CardToggleConfig]
    private let steppers: [CardStepperConfig]
    private let styleOptions: [CardStyleOptionConfig]
    private let onSelect: (Int?) -> Void
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rowButtons: [CardTrackRowButton] = []
    private var stepperRows: [UIView & CardStepperRowControl] = []
    /// Pin focus to the selected row only for the FIRST landing. After focus
    /// has entered the list once, `preferredFocusEnvironments` holds the row
    /// focus is on, so an edge press stops instead of bouncing to the selection.
    private var hasPinnedInitialFocus = false
    /// The control focus is on: a track row or a stepper's -/+ button.
    private weak var lastFocusedControl: UIView?

    private var stepperRefreshTimer: Timer?
    /// Fallback only, for a stepper with no `changePublisher`: long enough to
    /// span a debounced change elsewhere in this panel (a press, or an
    /// action like Audio Sync's "Reset to 0 ms", settling). A stepper that
    /// DOES supply a `changePublisher` is refreshed precisely instead (see
    /// `setupViews`) and doesn't depend on this window being long enough.
    private static let stepperRefreshWindow: TimeInterval = 3.0
    private static let stepperRefreshInterval: TimeInterval = 0.15
    private var cancellables = Set<AnyCancellable>()

    convenience init(header: String, tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool,
                     actions: [CardActionConfig] = [],
                     toggles: [CardToggleConfig] = [], steppers: [CardStepperConfig] = [],
                     styleOptions: [CardStyleOptionConfig] = [],
                     onSelect: @escaping (Int?) -> Void) {
        var rows: [Row] = []
        if showsOffRow {
            rows.append(Row(title: "Off", subtitle: nil, trackId: nil, isSelected: selectedTrackId == nil))
        }
        rows.append(contentsOf: tracks.map { track in
            Row(
                title: track.name,
                subtitle: [track.language, track.codec?.uppercased()].compactMap { $0 }.joined(separator: " • "),
                trackId: track.id,
                isSelected: track.id == selectedTrackId
            )
        })
        self.init(header: header, rows: rows, actions: actions, toggles: toggles, steppers: steppers,
                  styleOptions: styleOptions, onSelect: onSelect)
    }

    /// A plain list of choices: each row's `trackId` is what `onSelect` receives.
    init(header: String, rows: [Row], actions: [CardActionConfig] = [], toggles: [CardToggleConfig] = [],
         steppers: [CardStepperConfig] = [], styleOptions: [CardStyleOptionConfig] = [],
         onSelect: @escaping (Int?) -> Void) {
        self.rows = rows
        self.actions = actions
        self.toggles = toggles
        self.steppers = steppers
        self.styleOptions = styleOptions
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupViews(header: header)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews(header: String) {
        let headerLabel = UILabel()
        headerLabel.text = header
        headerLabel.font = Metrics.secondaryFont
        headerLabel.textColor = Metrics.secondaryColor
        addSubview(headerLabel)

        stack.axis = .vertical
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // The scroll view grows with content up to the popup's cap, so short
        // lists hug their rows and long ones scroll. Kept below the header's
        // compression resistance so an overflow scrolls instead of squashing it.
        let scrollHeight = scrollView.heightAnchor.constraint(
            equalTo: stack.heightAnchor, constant: Metrics.bottomInset)
        scrollHeight.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            headerLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.headerLabelCenterY),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.headerLabelLeading),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.headerLabelLeading),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Metrics.bottomInset),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * Metrics.rowInset),
        ])

        for row in rows {
            let button = CardTrackRowButton(row: row)
            button.onTap = { [weak self] in
                self?.onSelect(row.trackId)
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        // Actions (Search for Subtitles) get their own section; the handler
        // decides what happens to the popup.
        if !actions.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in actions {
            let button = CardTrackRowButton(row: Row(title: config.title, subtitle: nil, trackId: nil, isSelected: false))
            button.onTap = { [weak self, weak button] in
                guard let button else { return }
                config.run(button)
                // An action can change a stepper's value elsewhere in this
                // same panel (Audio Sync's "Reset to Default"), possibly
                // asynchronously (its own debounced apply) — keep every
                // stepper row's label in sync for a few seconds either way.
                self?.scheduleStepperRefresh()
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        // On/off toggles (Enhance Dialogue, Reduce Loud Sounds) get their own
        // section; a press flips the checkmark in place and leaves the popup up.
        if !toggles.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in toggles {
            let button = CardTrackRowButton(row: Row(title: config.title, subtitle: nil, trackId: nil,
                                                     isSelected: config.isOn()))
            button.onTap = { [weak button] in
                guard let button else { return }
                let on = !button.isChecked
                config.onToggle(on)
                button.isChecked = on
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        // Adjustment steppers (delay / height) sit in their own section below a
        // separator. A press adjusts in place and leaves the popup up, so the
        // user can watch the subtitles move as they step.
        if !steppers.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        for config in steppers {
            let row: UIView & CardStepperRowControl = config.usesArrowKeys
                ? CardArrowStepperRowView(config: config)
                : CardStepperRowView(config: config)
            row.onStep = { [weak self] in self?.scheduleStepperRefresh() }
            // A stepper whose value can change on its own after a press
            // lands (Audio Sync's debounced apply) supplies a publisher so
            // this refreshes exactly when that happens, rather than relying
            // on `scheduleStepperRefresh`'s fixed window being long enough.
            if let changePublisher = config.changePublisher {
                changePublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak row] in row?.refreshValue() }
                    .store(in: &cancellables)
            }
            stack.addArrangedSubview(row)
            stepperRows.append(row)
        }

        // Caption style presets (Use System Setting / Default / Large Text /
        // ...): live preview as focus moves between them, like the rail's
        // info pills switching tabs on focus rather than on a separate
        // select — not a toggle, so moving off a row never unchecks it on
        // its own; only another row gaining focus moves the checkmark.
        if !styleOptions.isEmpty, !rowButtons.isEmpty {
            stack.addArrangedSubview(MenuSeparatorView())
        }
        var styleOptionButtons: [CardTrackRowButton] = []
        for config in styleOptions {
            let button = CardTrackRowButton(row: Row(
                title: config.title, subtitle: nil, trackId: nil, isSelected: config.isSelected()))
            button.onFocusChanged = { [weak button] focused in
                guard focused, let button else { return }
                config.onFocus()
                styleOptionButtons.forEach { $0.isChecked = ($0 === button) }
            }
            button.onTap = { config.onFocus() }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
            styleOptionButtons.append(button)
        }
    }

    /// Keeps every stepper row's label in sync with its own `config.value()`
    /// for a few seconds after a press or an action — not just at the press
    /// itself — since a value here can change asynchronously afterward (a
    /// debounced apply) or be changed by a DIFFERENT control in this same
    /// panel. No row needs to know why; it only needs to be re-read.
    private func scheduleStepperRefresh() {
        guard !stepperRows.isEmpty else { return }
        stepperRefreshTimer?.invalidate()
        let deadline = Date().addingTimeInterval(Self.stepperRefreshWindow)
        let timer = Timer(timeInterval: Self.stepperRefreshInterval, repeats: true) { [weak self] pollTimer in
            guard let self else { pollTimer.invalidate(); return }
            self.stepperRows.forEach { $0.refreshValue() }
            if Date() >= deadline { pollTimer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepperRefreshTimer = timer
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // After the first landing, hold the CURRENT row: when an edge press
        // finds no in-popup candidate the popup's fence re-resolves through
        // here, and returning the focused row makes focus stop at the edge
        // instead of looping to the top.
        if hasPinnedInitialFocus {
            return lastFocusedControl.map { [$0] } ?? []
        }
        if let first = rowButtons.first(where: { $0.row.isSelected }) {
            return [first]
        }
        if let firstRow = rowButtons.first { return [firstRow] }
        return stepperRows.isEmpty ? [self] : [stepperRows[0]]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: self) else { return }
        if let row = rowButtons.first(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
            lastFocusedControl = row
        } else if stepperRows.contains(where: { next.isDescendant(of: $0) }) {
            // Either the row itself is focusable (CardArrowStepperRowView,
            // which `isDescendant(of:)` counts as true for itself) or one of
            // its -/+ buttons is (CardStepperRowView).
            hasPinnedInitialFocus = true
            lastFocusedControl = next
        }
    }
}

// MARK: - MenuSeparatorView

/// AVKit's section break: an 18pt gap, then a 1pt line inset 15pt from the rows.
private final class MenuSeparatorView: UIView {
    init() {
        super.init(frame: .zero)
        let line = UIView()
        line.backgroundColor = CardTrackListView.Metrics.separatorColor
        addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CardTrackListView.Metrics.separatorGap + 1),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardTrackListView.Metrics.separatorInset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardTrackListView.Metrics.separatorInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - CardActionConfig

/// A row that runs `run`, which receives the row so it can retitle it.
struct CardActionConfig {
    let title: String
    let run: (CardTrackRowButton) -> Void
}

// MARK: - CardToggleConfig

struct CardToggleConfig {
    let title: String
    let isOn: () -> Bool
    let onToggle: (Bool) -> Void
}

// MARK: - CardStyleOptionConfig

/// One row in a mutually-exclusive, focus-driven choice list (the player's
/// caption style presets): unlike a toggle, selection follows FOCUS, not a
/// tap — `onFocus` fires the moment this row is focused, and the row's own
/// checkmark is the container's job (`CardTrackListView.setupViews`), since
/// gaining it must move the mark off whichever row had it before.
struct CardStyleOptionConfig {
    let title: String
    let isSelected: () -> Bool
    let onFocus: () -> Void
}

// MARK: - CardStepperConfig

/// One adjustment stepper in the menu: a title, a formatted value provider,
/// and a step handler (`-1` / `+1`). The row re-reads `value()` after every
/// press, so the handler owns clamping and persistence.
struct CardStepperConfig {
    let title: String
    let value: () -> String
    let onStep: (Int) -> Void
    /// True to render as a single focusable row where Left/Right step the
    /// value directly (hold to repeat-accelerate), instead of separate -/+
    /// buttons — used where a dedicated row earns it (Audio Sync). Defaults
    /// to false: Height/Delay keep the two-button form.
    var usesArrowKeys: Bool = false
    /// Fires whenever `value()` might have changed WITHOUT a press on this
    /// row — a debounced apply landing (Audio Sync), or another control in
    /// the same panel changing it (its "Reset to 0 ms" action). Lets the row
    /// refresh exactly when that happens instead of guessing how long to
    /// keep polling. Optional: a stepper whose value only ever changes on
    /// its own press (Height, Delay) can leave this nil.
    var changePublisher: AnyPublisher<Void, Never>? = nil
    /// Fires when Down (press or swipe) arrives on this row with nowhere to
    /// go — only meaningful for the LAST stepper in a list that wants Down
    /// to dismiss rather than dead-end (the player's top quick-adjust
    /// panel). Consumed before the focus engine ever sees the press, so it
    /// works regardless of what a container's own edge-of-list fencing
    /// would otherwise do. Nil everywhere else.
    var onDownAtEnd: (() -> Void)? = nil
    /// Same idea for Up on the FIRST stepper in such a list — the top
    /// quick-adjust panel closes on Up past its top row (it slides back up,
    /// mirroring how it opened), while Down past the bottom row does
    /// nothing (see `onDownAtEnd`). Nil everywhere else.
    var onUpAtStart: (() -> Void)? = nil
}

/// Shared by both stepper row kinds, so `CardTrackListView` can hold either
/// in one array without caring which it has.
protocol CardStepperRowControl: AnyObject {
    /// Fires after every step, so the owning list can keep every row (not
    /// just this one) in sync for a few seconds afterward — a press here can
    /// change a value shown elsewhere, and a control elsewhere (Audio Sync's
    /// "Reset to 0 ms" action) can change THIS row's value.
    var onStep: (() -> Void)? { get set }
    /// Re-reads the config's `value()` without a press — the owning list
    /// calls this on a timer after ANY control in the panel changes, since a
    /// row can't tell on its own when that happens.
    func refreshValue()
}

// MARK: - HoldRepeater

/// Fires once immediately, then repeats while held — starting after
/// `InputConfig.holdThreshold`, speeding up the longer the hold continues.
/// Shared by `CardStepperButton` (a held Select) and `CardArrowStepperRowView`
/// (a held Left/Right), which each just supply what firing means.
final class HoldRepeater {
    private var repeatTimer: Timer?
    private var holdStarted: Date?
    /// Repeat cadence once held past `InputConfig.holdThreshold`.
    private static let repeatInterval: TimeInterval = 0.25
    /// Faster cadence once the hold has run this long — a big adjustment
    /// doesn't take forever at 10ms/press, a small one stays precise.
    private static let fastRepeatInterval: TimeInterval = 0.08
    private static let fastRepeatDelay: TimeInterval = 1.5

    /// `fire` also runs immediately, matching the single-press feel of an
    /// ordinary tap; nothing repeats for one released before the threshold,
    /// since `end()` invalidates the pending timer first.
    func begin(fire: @escaping () -> Void) {
        fire()
        holdStarted = Date()
        repeatTimer?.invalidate()
        let pending = Timer(timeInterval: InputConfig.holdThreshold, repeats: false) { [weak self] _ in
            self?.startRepeating(interval: Self.repeatInterval, fire: fire)
        }
        RunLoop.main.add(pending, forMode: .common)
        repeatTimer = pending
    }

    private func startRepeating(interval: TimeInterval, fire: @escaping () -> Void) {
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            fire()
            // Swap to the faster cadence once the hold has run long enough,
            // rather than trying to retime the running timer in place.
            if interval != Self.fastRepeatInterval,
               let started = self.holdStarted,
               Date().timeIntervalSince(started) >= Self.fastRepeatDelay {
                self.startRepeating(interval: Self.fastRepeatInterval, fire: fire)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    func end() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        holdStarted = nil
    }
}

// MARK: - CardStepperRowView

/// `Title        (-)  value  (+)` in a menu row — the two-button form. The
/// -/+ buttons are focusable; the value updates on every press.
final class CardStepperRowView: UIView, CardStepperRowControl {

    private let config: CardStepperConfig
    private let valueLabel = UILabel()
    private let minus = CardStepperButton(symbolName: "minus")
    private let plus = CardStepperButton(symbolName: "plus")

    /// The `+` button — the natural first-focus landing when this row is the
    /// only control on a dedicated page (Settings' global-default modal).
    var incrementButton: UIView { plus }

    var onStep: (() -> Void)?

    init(config: CardStepperConfig) {
        self.config = config
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = config.title
        titleLabel.font = CardTrackListView.Metrics.titleFont
        titleLabel.textColor = .white

        minus.onTap = { [weak self] in self?.step(-1) }
        plus.onTap = { [weak self] in self?.step(+1) }

        valueLabel.text = config.value()
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        valueLabel.textColor = CardTrackListView.Metrics.secondaryColor
        valueLabel.textAlignment = .center

        [titleLabel, minus, valueLabel, plus].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let button: CGFloat = 52
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CardTrackListView.Metrics.rowHeight),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardTrackListView.Metrics.titleX),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            plus.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: button),
            plus.heightAnchor.constraint(equalToConstant: button),

            valueLabel.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),

            minus.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -8),
            minus.centerYAnchor.constraint(equalTo: centerYAnchor),
            minus.widthAnchor.constraint(equalToConstant: button),
            minus.heightAnchor.constraint(equalToConstant: button),
            minus.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func step(_ direction: Int) {
        config.onStep(direction)
        valueLabel.text = config.value()
        onStep?()
    }

    func refreshValue() {
        valueLabel.text = config.value()
    }
}

// MARK: - CardStepperButton

/// Round -/+ control: faint fill at rest, white with a black glyph when focused.
final class CardStepperButton: UIControl {

    var onTap: (() -> Void)?
    private let symbolView: UIImageView
    private let holdRepeater = HoldRepeater()

    init(symbolName: String) {
        symbolView = UIImageView(image: UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        ))
        super.init(frame: .zero)

        symbolView.tintColor = .white
        symbolView.contentMode = .center
        addSubview(symbolView)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        backgroundColor = UIColor.white.withAlphaComponent(0.1)
        layer.cornerRadius = 26
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl on tvOS.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            holdRepeater.begin { [weak self] in self?.onTap?() }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            holdRepeater.end()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            holdRepeater.end()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: isFocused) {
            self.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.1)
            self.symbolView.tintColor = isFocused ? .black : .white
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
        }
    }
}

// MARK: - CardArrowStepperRowView

/// `Title                      value` in a menu row, itself focusable: while
/// focused, Left/Right step the value directly (hold to repeat-accelerate,
/// via the same `HoldRepeater` `CardStepperButton` uses), rather than
/// separate -/+ buttons. Focus styling mirrors `CardTrackRowButton`'s pill.
final class CardArrowStepperRowView: UIView, CardStepperRowControl {

    private let config: CardStepperConfig
    private let pill = UIView()
    private let content = UIView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let holdRepeater = HoldRepeater()
    /// The touch-remote / iPhone-Remote twin of the press handling below:
    /// those arrive as indirect-touch swipes, never as arrow presses at all,
    /// so without this a touch-only remote couldn't adjust this row. Gated
    /// to fire only while this row holds focus, same as the press half.
    private var swipeBinding: DirectionalInputBinding?

    var onStep: (() -> Void)?

    init(config: CardStepperConfig) {
        self.config = config
        super.init(frame: .zero)
        typealias M = CardTrackListView.Metrics

        pill.layer.cornerRadius = M.rowRadius
        pill.layer.cornerCurve = .continuous
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOffset = CGSize(width: 0, height: 20)
        pill.layer.shadowRadius = 15
        pill.isUserInteractionEnabled = false
        content.isUserInteractionEnabled = false

        titleLabel.text = config.title
        titleLabel.font = M.titleFont
        titleLabel.textColor = .white

        valueLabel.text = config.value()
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        valueLabel.textColor = M.secondaryColor
        valueLabel.textAlignment = .right

        addSubview(pill)
        addSubview(content)
        [titleLabel, valueLabel].forEach { content.addSubview($0) }
        [content, titleLabel, valueLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: M.rowHeight),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.titleX),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -M.checkColumnX),
            valueLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
        ])
        applyFocus(false)

        swipeBinding = DirectionalInputBinding(
            gatedSwipesOn: self,
            directions: [.left, .right, .down, .up],
            shouldHandle: { [weak self] direction in
                guard let self, self.isFocused else { return false }
                switch direction {
                case .left, .right: return true
                case .down: return self.config.onDownAtEnd != nil
                case .up: return self.config.onUpAtStart != nil
                }
            },
            onSwipe: { [weak self] direction in
                switch direction {
                case .left: self?.step(-1)
                case .right: self?.step(1)
                case .down: self?.config.onDownAtEnd?()
                case .up: self?.config.onUpAtStart?()
                }
            }
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isFocused = self.isFocused
        pill.frame = isFocused ? bounds.insetBy(dx: -CardTrackListView.Metrics.focusGrowth,
                                                dy: -CardTrackListView.Metrics.focusGrowth) : bounds
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
    }

    // Left/Right step the value directly while focused. Up/Down dismiss only
    // when this row opted in (the top/bottom row of the player's top
    // quick-adjust panel); Select and Menu always pass through untouched.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .leftArrow:
                holdRepeater.begin { [weak self] in self?.step(-1) }
                return
            case .rightArrow:
                holdRepeater.begin { [weak self] in self?.step(1) }
                return
            case .downArrow where config.onDownAtEnd != nil:
                config.onDownAtEnd?()
                return
            case .upArrow where config.onUpAtStart != nil:
                config.onUpAtStart?()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            holdRepeater.end()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            holdRepeater.end()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: isFocused) {
            self.applyFocus(isFocused)
        }
    }

    private func applyFocus(_ focused: Bool) {
        typealias M = CardTrackListView.Metrics
        let growth = focused ? M.focusGrowth : 0
        pill.frame = bounds.insetBy(dx: -growth, dy: -growth)
        pill.layer.cornerRadius = M.rowRadius + growth
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
        pill.backgroundColor = focused ? .white : .clear
        pill.layer.shadowOpacity = focused ? 0.3 : 0
        content.transform = focused ? CGAffineTransform(scaleX: M.focusScale, y: M.focusScale) : .identity
        titleLabel.textColor = focused ? .black : .white
        valueLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.6) : M.secondaryColor
    }

    private func step(_ direction: Int) {
        config.onStep(direction)
        valueLabel.text = config.value()
        onStep?()
    }

    func refreshValue() {
        valueLabel.text = config.value()
    }
}

// MARK: - CardTrackRowButton

/// One menu row: checkmark column, title, optional second line. Focused, a
/// white pill grows 4pt past the row with AVKit's shadow and the content scales
/// with it.
final class CardTrackRowButton: UIControl {

    let row: CardTrackListView.Row
    var onTap: (() -> Void)?
    /// Fires on every focus change, gained or lost. Nil for every row except
    /// the caption style presets, which preview live as focus moves.
    var onFocusChanged: ((Bool) -> Void)?
    var isChecked: Bool {
        get { !checkmarkView.isHidden }
        set { checkmarkView.isHidden = !newValue }
    }
    private let pill = UIView()
    private let content = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(
        systemName: "checkmark",
        // Matches AVKit's glyph by rendered ink, not by its reported 19x17 size.
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
    ))

    init(row: CardTrackListView.Row) {
        self.row = row
        super.init(frame: .zero)
        typealias M = CardTrackListView.Metrics

        let hasSubtitle = !(row.subtitle?.isEmpty ?? true)

        pill.layer.cornerRadius = M.rowRadius
        pill.layer.cornerCurve = .continuous
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOffset = CGSize(width: 0, height: 20)
        pill.layer.shadowRadius = 15
        pill.isUserInteractionEnabled = false
        content.isUserInteractionEnabled = false

        titleLabel.text = row.title
        titleLabel.font = M.titleFont
        titleLabel.textColor = .white

        subtitleLabel.text = row.subtitle
        subtitleLabel.font = M.secondaryFont
        subtitleLabel.textColor = M.secondaryColor
        subtitleLabel.isHidden = !hasSubtitle

        checkmarkView.tintColor = .white
        checkmarkView.isHidden = !row.isSelected
        checkmarkView.contentMode = .center

        addSubview(pill)
        addSubview(content)
        [checkmarkView, titleLabel, subtitleLabel].forEach { content.addSubview($0) }

        [content, checkmarkView, titleLabel, subtitleLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        var constraints = [
            heightAnchor.constraint(equalToConstant: hasSubtitle ? M.twoLineRowHeight : M.rowHeight),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),

            checkmarkView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.checkColumnX),
            checkmarkView.widthAnchor.constraint(equalToConstant: M.checkColumnWidth),
            checkmarkView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: M.titleX),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -M.checkColumnX),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -M.checkColumnX),
        ]
        if hasSubtitle {
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
                subtitleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 45),
            ]
        } else {
            constraints.append(titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        applyFocus(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) { titleLabel.text = title }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isFocused = self.isFocused
        pill.frame = isFocused ? bounds.insetBy(dx: -CardTrackListView.Metrics.focusGrowth,
                                                dy: -CardTrackListView.Metrics.focusGrowth) : bounds
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
    }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl
    // on tvOS; handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        onFocusChanged?(isFocused)
        coordinator.animateFocusChange(gained: isFocused) {
            self.applyFocus(isFocused)
        }
    }

    private func applyFocus(_ focused: Bool) {
        typealias M = CardTrackListView.Metrics
        let growth = focused ? M.focusGrowth : 0
        pill.frame = bounds.insetBy(dx: -growth, dy: -growth)
        pill.layer.cornerRadius = M.rowRadius + growth
        pill.layer.shadowPath = UIBezierPath(roundedRect: pill.bounds, cornerRadius: pill.layer.cornerRadius).cgPath
        pill.backgroundColor = focused ? .white : .clear
        pill.layer.shadowOpacity = focused ? 0.3 : 0
        content.transform = focused ? CGAffineTransform(scaleX: M.focusScale, y: M.focusScale) : .identity
        titleLabel.textColor = focused ? .black : .white
        subtitleLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.6) : M.secondaryColor
        checkmarkView.tintColor = focused ? .black : .white
    }
}

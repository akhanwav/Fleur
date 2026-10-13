// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicLyricsPaneView.swift
//  Rivulet
//
//  Now Playing's lyrics: 76pt bold lines from x 840 that scroll with the song,
//  the sung lyric bright, the ones ahead dim and the ones behind gone. Plex
//  times whole lines, so the highlight is per line. Never focusable: the page's
//  hidden-controls anchor browses the lines through `step`, the drag calls and
//  `commitSelection`.
//  Constants and timings are Apple Music's on tvOS 26.
//

import UIKit

@MainActor
final class MusicLyricsPaneView: UIView {
    private static let font = UIFont.systemFont(ofSize: 76, weight: .bold)
    /// Space between two lyrics. A wrapped lyric keeps the font's own line height.
    private static let gap: CGFloat = 100
    /// Apple's wrap width: no lyric passes x 1730.
    private static let wrap: CGFloat = 890
    /// The sung lyric's text block is centred here, whatever its line count.
    private static let centre: CGFloat = 384 + ceil(font.lineHeight) / 2
    /// Labels kept around the sung lyric: the one fading out above it, and those in sight below.
    private static let window = -1...7
    /// While browsing, the lines above are in sight again.
    private static let browseWindow = -3...7
    /// The first lyric starts this far under the countdown.
    private static let countdownGap: CGFloat = 70

    /// The song's position now, or nil while there is none to follow.
    var clock: (() -> TimeInterval?)?
    /// True while the timeline scans: the clock outruns the scroll spring, so the column is placed.
    var isScanning: (() -> Bool)?
    private var wasScanning = false

    /// The timestamp over the browsed line. The page adds it as a sibling: this layer's filter would eat it.
    let pill = MusicLyricsTimestampPill()
    private var browse = MusicLyricsBrowse()
    private var dragStart: CGFloat = 0
    /// The line the timestamp is up on, nil while it is not shown.
    private var pillLine: Int?

    var isBrowsing: Bool { browse.isBrowsing }
    private var column: MusicLyricsColumn { MusicLyricsColumn(tops: tops, heights: heights, centre: Self.centre) }
    private var selectedAlpha: CGFloat { traitCollection.accessibilityContrast == .high ? 0.8 : 0.35 }

    private let fade = GradientView()
    private let dots = UIView()
    private let bullets = (0..<3).map { _ in UILabel() }
    private let sizer = UILabel()
    private var link: CADisplayLink?
    private var lines: [MusicLyricLine] = []
    private var tops: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var labels: [Int: UILabel] = [:]
    private var active: Int?
    /// Where the column sits: a label's y is its top plus this.
    private var offset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        fade.gradientLayer.colors = [UIColor.clear, .white, .white, .clear].map(\.cgColor)
        mask = fade
        setControlsVisible(true)
        sizer.numberOfLines = 0

        // Apple's countdown: three 72pt bullets, overlapped by 3pt and drawn 6pt high.
        var x: CGFloat = 0
        for bullet in bullets {
            bullet.text = "\u{2022}"
            bullet.font = .systemFont(ofSize: 72, weight: .bold)
            bullet.textColor = .white
            bullet.sizeToFit()
            bullet.frame.origin = CGPoint(x: x, y: -6)
            x = bullet.frame.maxX - 3
            dots.addSubview(bullet)
        }
        dots.bounds.size = CGSize(width: x + 3, height: bullets[0].bounds.height)
        dots.center.x = dots.bounds.width / 2
        addSubview(dots)

        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (self: Self, _: UITraitCollection) in
            self.applyContrast()
        }
        applyContrast()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func text(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = .pushOut
        paragraph.hyphenationFactor = 0.1
        return NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: paragraph])
    }

    func setLines(_ lines: [MusicLyricLine]) {
        // The labels are about to go: no browsed line outlives them.
        _ = browse.cancel()
        setPill(nil, animated: false)
        self.lines = lines
        labels.values.forEach { $0.removeFromSuperview() }
        labels = [:]
        var y: CGFloat = 0
        (tops, heights) = ([], [])
        for line in lines {
            // Measured by a label, so the wrap is the one that draws.
            sizer.attributedText = Self.text(line.text)
            let height = ceil(sizer.sizeThatFits(CGSize(width: Self.wrap, height: .greatestFiniteMagnitude)).height)
            tops.append(y)
            heights.append(height)
            y += height + Self.gap
        }
        show(nil, animated: false)
        fillCountdown(elapsed: 0)
        sync(animated: false)
    }

    /// Apple's edge fade: 119pt ramps at the top and above the upper buttons, or at the
    /// screen's foot once the controls are gone.
    func setControlsVisible(_ visible: Bool) {
        let height: CGFloat = visible ? 816 : 1080
        fade.frame = CGRect(x: 0, y: 0, width: 2000, height: height)
        fade.gradientLayer.locations = [0, 119 / height, 1 - 119 / height, 1].map { NSNumber(value: $0) }
    }

    // MARK: - Clock

    // Apple reads the song's clock every frame. Common modes: a menu's tracking must not stall it.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else {
            endBrowsing(animated: false)
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.isPaused = isHidden
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    // Out of sight the song moves on: coming back, the column is placed, not scrolled.
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            link?.isPaused = isHidden
            if isHidden { endBrowsing(animated: false) } else { sync(animated: false) }
        }
    }

    @objc private func tick() {
        // The frame that ends a scan is placed too: its last step may not have been drawn yet.
        let scanning = isScanning?() == true
        sync(animated: !scanning && !wasScanning)
        wasScanning = scanning
        trackPill()
    }

    /// The line due within the lead is the sung one. Before the first, the countdown fills.
    private func sync(animated: Bool) {
        guard !lines.isEmpty, let time = clock?() else { return }
        let index = lines.activeIndex(at: time, lead: MusicLyricLine.lead)
        // Browsing, the clock keeps the sung line current and moves nothing.
        if browse.isBrowsing {
            active = index
            return
        }
        if index != active { show(index, animated: animated) }
        if index == nil { fillCountdown(elapsed: time) }
    }

    // MARK: - Look

    /// Lines ahead: added to the ground at 17.5%, or drawn at 35% under Increase Contrast.
    private var dim: CGFloat { traitCollection.accessibilityContrast == .high ? 0.35 : 0.175 }

    private func applyContrast() {
        layer.compositingFilter = traitCollection.accessibilityContrast == .high ? nil : "plusL"
        endBrowsing(animated: false)
        show(active, animated: false)
    }

    private func alpha(of item: Int) -> CGFloat {
        // Browsing has no bright line: the one under the timestamp is twice the others.
        if browse.isBrowsing { return item == pillLine ? selectedAlpha : dim }
        guard let active else { return dim }
        return item < active ? 0 : (item == active ? 1 : dim)
    }

    /// The bullets light left to right over the wait for the first line.
    static func countdownAlphas(elapsed: TimeInterval, start: TimeInterval, dim: CGFloat) -> [CGFloat] {
        // A first line inside 2s gets full bullets at once.
        let filled = start < 2 ? 3 : 3 * min(1, max(0, elapsed / start))
        return (0..<3).map { bullet in
            Double(bullet) <= filled.rounded(.down) ? min(1, dim + (filled - Double(bullet)) * (1 - dim)) : dim
        }
    }

    private func fillCountdown(elapsed: TimeInterval) {
        guard let start = lines.first?.start else { return }
        for (bullet, alpha) in zip(bullets, Self.countdownAlphas(elapsed: elapsed, start: start, dim: dim)) {
            bullet.alpha = alpha
        }
        // A long wait breathes: one swell to 1.2 for every 4s of it.
        let swells = (start / 4).rounded(.down)
        guard start > 3, swells >= 1, !UIAccessibility.isReduceMotionEnabled else { return dots.transform = .identity }
        let scale = 1.1 - 0.1 * cos(2 * .pi * swells * elapsed / start)
        dots.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    // MARK: - Column

    /// Following's writer of `offset`. `scroll` is the other, and the phase picks one.
    private func show(_ index: Int?, animated: Bool) {
        assert(!browse.isBrowsing)
        let step = (index ?? -1) - (active ?? -1)
        active = index
        guard !lines.isEmpty else { return }
        // Apple cascades only from rest: lines still on their way just follow the column.
        let resting = labels.values.allSatisfy { abs(($0.layer.presentation() ?? $0.layer).frame.minY - $0.frame.minY) < 2 }
        let animated = animated && !UIAccessibility.isReduceMotionEnabled
        let target = index.map(column.offset(centring:))
            ?? (Self.centre + dots.bounds.height / 2 + Self.countdownGap).rounded()
        // Apple starts a long jump 1600pt short of where it ends.
        let from = animated ? target + min(1600, max(-1600, offset - target)) : target
        let jumped = from != offset
        offset = target

        keepLabels(around: index ?? 0, Self.window, at: from, replace: jumped)

        let first = index ?? 0
        let leave = {
            for (item, label) in self.labels where item < first { label.alpha = 0 }
            self.dots.alpha = index == nil ? 1 : 0
        }
        let light = { for (item, label) in self.labels where item >= first { label.alpha = self.alpha(of: item) } }
        guard animated else {
            leave()
            light()
            placeDots()
            for (item, label) in labels { label.frame.origin.y = tops[item] + offset }
            return
        }
        // Apple's timings: a line leaves in 0.28s and lights in 0.12s, apart from the move.
        UIViewPropertyAnimator(duration: 0.28, controlPoint1: CGPoint(x: 0.17, y: 0),
                               controlPoint2: CGPoint(x: 0.83, y: 1), animations: leave).startAnimation()
        UIViewPropertyAnimator(duration: 0.12, controlPoint1: CGPoint(x: 0.33, y: 0),
                               controlPoint2: CGPoint(x: 0.2, y: 1), animations: light).startAnimation()
        Self.spring(placeDots)
        for (item, label) in labels {
            // On a plain advance each line below follows 80ms after the one above it.
            let delay = step == 1 && resting ? 0.08 * Double(max(0, item - first)) : 0
            if delay == 0 {
                settle(item, label)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak label] in
                    if let label { self?.settle(item, label) }
                }
            }
        }
    }

    /// The labels of `window` around a line and no others. New ones start with the column at
    /// `offset`; with `replace` the ones in place move there too.
    private func keepLabels(around line: Int, _ window: ClosedRange<Int>, at offset: CGFloat, replace: Bool) {
        let wanted = Set(window.map { line + $0 }.filter(lines.indices.contains))
        for (item, label) in labels where !wanted.contains(item) {
            label.removeFromSuperview()
            labels[item] = nil
        }
        for (item, label) in labels where replace { label.frame.origin.y = tops[item] + offset }
        for item in wanted where labels[item] == nil {
            let label = UILabel(frame: CGRect(x: 0, y: tops[item] + offset, width: Self.wrap, height: heights[item]))
            label.numberOfLines = 0
            label.attributedText = Self.text(lines[item].text)
            label.textColor = .white
            label.alpha = alpha(of: item)
            addSubview(label)
            labels[item] = label
        }
    }

    private func placeDots() {
        dots.center.y = offset - Self.countdownGap - dots.bounds.height / 2
    }

    /// Springs a label to its place in the column as the column stands by then.
    private func settle(_ item: Int, _ label: UILabel) {
        // A cascade step that fires late must not start a spring under a finger.
        guard labels[item] === label, !browse.isBrowsing else { return }
        Self.spring { label.frame.origin.y = self.tops[item] + self.offset }
    }

    /// Apple's scroll spring. Its 0.76s period is the lead, so a line is in place as it is sung.
    /// `velocity` is in distances to travel per second.
    private static func spring(velocity: CGFloat = 0, _ animations: @escaping () -> Void) {
        let timing = UISpringTimingParameters(mass: 1, stiffness: 68, damping: 14,
                                              initialVelocity: CGVector(dx: 0, dy: velocity))
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
        animator.addAnimations(animations)
        animator.startAnimation()
    }

    // MARK: - Browsing

    /// An arrow press: one line earlier or later.
    func step(_ delta: Int) {
        let wasFollowing = !isBrowsing
        guard case .snap(let line) = browse.step(delta, sung: active, count: lines.count) else { return }
        if wasFollowing { enterBrowsing() }
        snap(to: line, velocity: 0)
    }

    func beginDrag() {
        guard !lines.isEmpty else { return }
        let wasFollowing = !isBrowsing
        browse.dragBegan(nearest: column.nearestLine(at: offset) ?? 0)
        if wasFollowing { enterBrowsing() }
        dragStart = offset
    }

    func drag(by translation: CGFloat) {
        guard case .dragging = browse.phase else { return }
        scroll(to: column.clamped(dragStart + translation * MusicLyricsColumn.panGain), spring: false)
    }

    func endDrag(velocity: CGFloat) {
        let velocity = velocity * MusicLyricsColumn.panGain
        let rest = column.clamped(MusicLyricsColumn.rest(from: offset, velocity: velocity))
        guard case .snap(let line) = browse.dragEnded(nearest: column.nearestLine(at: rest) ?? 0) else { return }
        snap(to: line, velocity: velocity)
    }

    /// Select on a browsed line: its start time, and the column follows the song again from it.
    /// Nil when the click only brought a drag to rest.
    func commitSelection() -> TimeInterval? {
        switch browse.select(nearest: column.nearestLine(at: offset) ?? 0, pillUp: pillLine != nil) {
        case .seek(let line):
            setPill(nil)
            // Shown as sung at once: `sync` would not redraw a jump to the line already being sung.
            show(line, animated: true)
            return lines[line].start
        case .snap(let line):
            snap(to: line, velocity: 0)
            return nil
        default:
            return nil
        }
    }

    /// Menu, the timeout, the controls returning, a new track: back to the sung line.
    // ponytail: lines above leave at once; let `show` keep the browse window for its fade if it shows.
    @discardableResult
    func endBrowsing(animated: Bool, timedOut: Bool = false) -> Bool {
        guard (timedOut ? browse.timeout() : browse.cancel()) == .follow else { return false }
        setPill(nil, animated: animated)
        show(active, animated: animated)
        return true
    }

    /// The hand-over from the song: every line dim and at rest in the column as it stands.
    private func enterBrowsing() {
        // A cascade's pending steps collapse now; `settle` refuses the late ones.
        let flush = { for (item, label) in self.labels { label.frame.origin.y = self.tops[item] + self.offset } }
        if UIAccessibility.isReduceMotionEnabled { flush() } else { Self.spring(flush) }
        let sung = active ?? 0
        keepLabels(around: column.nearestLine(at: offset) ?? 0, Self.browseWindow, at: offset, replace: false)
        // The lines above come back from nothing.
        for (item, label) in labels where item < sung { label.alpha = 0 }
        UIViewPropertyAnimator(duration: 0.12, controlPoint1: CGPoint(x: 0.33, y: 0), controlPoint2: CGPoint(x: 0.2, y: 1)) {
            for (item, label) in self.labels { label.alpha = self.alpha(of: item) }
            self.dots.alpha = 0
        }.startAnimation()
    }

    private func snap(to line: Int, velocity: CGFloat) {
        scroll(to: column.offset(centring: line), spring: true, velocity: velocity)
    }

    /// Browsing's writer of `offset`. `show` is the other, and the phase picks one.
    private func scroll(to target: CGFloat, spring: Bool, velocity: CGFloat = 0) {
        assert(browse.isBrowsing)
        let from = offset
        offset = target
        keepLabels(around: column.nearestLine(at: target) ?? 0, Self.browseWindow, at: from, replace: false)
        let place = {
            for (item, label) in self.labels { label.frame.origin.y = self.tops[item] + self.offset }
            self.placeDots()
        }
        if spring, !UIAccessibility.isReduceMotionEnabled {
            Self.spring(velocity: abs(target - from) < 1 ? 0 : velocity / (target - from), place)
        } else {
            UIView.performWithoutAnimation(place)
        }
    }

    /// Apple's rule, every frame: the timestamp is up while its line is within 40pt of rest,
    /// and sits on the label's top.
    private func trackPill() {
        guard let line = browse.namedLine, let label = labels[line] else { return setPill(nil) }
        let top = (label.layer.presentation() ?? label.layer).frame.minY
        setPill(MusicLyricsColumn.pillShows(distance: top - tops[line] - column.offset(centring: line)) ? line : nil)
        pill.frame.origin = convert(CGPoint(x: 0, y: top - pill.bounds.height), to: pill.superview)
    }

    /// Edge-triggered: the timestamp and its line's alpha change together, as Apple's do.
    private func setPill(_ line: Int?, animated: Bool = true) {
        guard line != pillLine else { return }
        let was = pillLine
        pillLine = line
        if let line { pill.setTime(lines[line].start) }
        pill.isHidden = false
        let changes = {
            self.pill.alpha = line == nil ? 0 : 0.9
            for item in [was, line].compactMap({ $0 }) { self.labels[item]?.alpha = self.alpha(of: item) }
        }
        // A view that is not shown covers nothing.
        let finish = { if self.pillLine == nil { self.pill.isHidden = true } }
        guard animated else { changes(); return finish() }
        UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: changes) { _ in finish() }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicLyricsBrowsing.swift
//  Rivulet
//
//  Browsing Now Playing's lyrics: where each line sits, whether the column
//  follows the song or the user, and the timestamp over the browsed line.
//  The distances and the timestamp's look are Apple Music's on tvOS 26.
//

import UIKit

/// Where each lyric sits in the column, and which one an offset centres. No views.
struct MusicLyricsColumn {
    let tops: [CGFloat]
    let heights: [CGFloat]
    let centre: CGFloat

    /// Apple's content inset: a drag may pass the first and last line this far.
    static let overscroll: CGFloat = 600
    /// Where a release rests under UIScrollView's fast deceleration: velocity times this.
    static let projection: CGFloat = 0.099
    /// Apple shows the timestamp within this distance of the line's rest.
    static let pillDistance: CGFloat = 40
    /// Points of column per point of touch. 1 is what a scroll view does; tune on a remote.
    static let panGain: CGFloat = 1

    /// The offset that centres a line's text block. Whole points: half a point blurs the text.
    func offset(centring line: Int) -> CGFloat { (centre - tops[line] - heights[line] / 2).rounded() }

    /// The line resting nearest the centre at `offset`; the earlier one on a tie. Nil when empty.
    // ponytail: linear scan, a song is a few hundred lines. Binary search if a trace ever shows it.
    func nearestLine(at offset: CGFloat) -> Int? {
        tops.indices.min { abs(self.offset(centring: $0) - offset) < abs(self.offset(centring: $1) - offset) }
    }

    // ponytail: a hard stop at the inset, no rubber band. Add one if the ends feel dead on a remote.
    func clamped(_ offset: CGFloat) -> CGFloat {
        guard let last = tops.indices.last else { return offset }
        return min(max(offset, self.offset(centring: last) - Self.overscroll),
                   self.offset(centring: 0) + Self.overscroll)
    }

    static func rest(from offset: CGFloat, velocity: CGFloat) -> CGFloat { offset + velocity * projection }

    static func pillShows(distance: CGFloat) -> Bool { abs(distance) < pillDistance }

    /// A line's start, kept a second inside a known duration so a jump cannot end the track.
    static func seekTime(_ start: TimeInterval, duration: TimeInterval) -> TimeInterval {
        max(0, duration > 1 ? min(start, duration - 1) : start)
    }
}

/// Whether the lyrics follow the song or the user. No views, no clock.
struct MusicLyricsBrowse: Equatable {
    enum Phase: Equatable {
        case following
        /// A finger has the column. `from` was centred when it took hold; `named` when the pill was its.
        case dragging(from: Int, named: Bool)
        /// The line rests at the centre, or is springing there.
        case selected(Int)
    }
    enum Effect: Equatable { case none, snap(Int), seek(Int), follow }

    private(set) var phase = Phase.following
    var isBrowsing: Bool { phase != .following }

    /// The line the timestamp may sit on.
    var namedLine: Int? {
        switch phase {
        case .selected(let line), .dragging(let line, true): line
        default: nil
        }
    }

    /// An arrow press. `sung` is the line being sung, nil before the first.
    mutating func step(_ delta: Int, sung: Int?, count: Int) -> Effect {
        guard count > 0 else { return .none }
        let base: Int
        switch phase {
        case .following: base = sung ?? -1
        // A press beats the drag, from the line the finger found.
        case .dragging(let from, _): base = from
        case .selected(let line): base = line
        }
        let line = min(max(base + delta, 0), count - 1)
        guard phase != .selected(line) else { return .none }
        phase = .selected(line)
        return .snap(line)
    }

    mutating func dragBegan(nearest: Int) {
        switch phase {
        case .following: phase = .dragging(from: nearest, named: false)
        case .selected(let line): phase = .dragging(from: line, named: true)
        case .dragging: break
        }
    }

    mutating func dragEnded(nearest: Int) -> Effect {
        guard case .dragging = phase else { return .none }
        phase = .selected(nearest)
        return .snap(nearest)
    }

    /// Select. `.none` means not consumed: the press is the usual play/pause.
    mutating func select(nearest: Int, pillUp: Bool) -> Effect {
        switch phase {
        case .following:
            return .none
        case .selected(let line):
            phase = .following
            return .seek(line)
        case .dragging(let from, let named):
            if named, pillUp {
                phase = .following
                return .seek(from)
            }
            // No timestamp names a line: the click only brings the column to rest.
            phase = .selected(nearest)
            return .snap(nearest)
        }
    }

    /// Menu, the controls coming back, a new track.
    mutating func cancel() -> Effect {
        guard isBrowsing else { return .none }
        phase = .following
        return .follow
    }

    /// Ten seconds without input. Not while a finger holds the column.
    mutating func timeout() -> Effect {
        guard case .selected = phase else { return .none }
        phase = .following
        return .follow
    }
}

/// The start time over the browsed lyric: Apple's focused look, a white capsule with a play glyph.
@MainActor
final class MusicLyricsTimestampPill: UIView {
    private let glyph = UIImageView(image: UIImage(systemName: "play.fill"))
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Shown only over a browsed line: a hidden view covers no focus item.
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0
        backgroundColor = .white
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.1
        layer.shadowOffset = CGSize(width: 2, height: 8)
        glyph.tintColor = .black
        glyph.contentMode = .scaleAspectFit
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .black
        [glyph, label].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Apple's metrics: 16, the 17x20 glyph, 4, the time, 16; 10 above and below.
    func setTime(_ seconds: TimeInterval) {
        label.text = MusicChrome.clock(seconds)
        label.sizeToFit()
        bounds.size = CGSize(width: label.bounds.width + 53, height: label.bounds.height + 20)
        glyph.frame = CGRect(x: 16, y: bounds.midY - 10, width: 17, height: 20)
        label.frame.origin = CGPoint(x: 37, y: 10)
        layer.cornerRadius = bounds.height / 2
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProgressInfoBar.swift
//  Rivulet
//
//  Reusable bottom-bar composition shared by `ContinueWatchingCell` and
//  in-progress tiles in `PosterCell`. Mirrors SwiftUI
//  `ContinueWatchingCard.bottomInfoBar` (`ContinueWatchingCard.swift:105`):
//
//    [▶︎]  [▓▓▓░░ progress 34pt]  S1, E2 · 35m
//
//  Sizes, gaps and colours are the Apple TV app's Up Next status row:
//   - play.fill glyph (20pt regular, small scale)
//   - 34 x 6 progress pill, hidden when not in progress
//   - info text (20pt medium): "S{n}, E{n}" for episodes plus
//     remaining-or-duration ("1h 7m" / "35m")
//  All three are white at half alpha, and full white on the focused card.
//
//  The play icon and the progress capsule both render ONLY when the item
//  has real play progress (0 < fraction < 1); an "up next" episode with no
//  progress shows just the info text. The bar sits directly on the artwork
//  — no dark gradient/scrim behind it.
//

import UIKit

@MainActor
final class MediaProgressInfoBar: UIView {

    private let playIcon = UIImageView()
    private let progressContainer = UIView()
    private let progressBackground = UIView()
    private let progressFill = UIView()
    private let infoLabel = UILabel()
    private let stack = UIStackView()

    private var progressFillWidthConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        playIcon.translatesAutoresizingMaskIntoConstraints = false
        // Apple's Up Next row: label colours resolved dark, whatever the app's style.
        overrideUserInterfaceStyle = .dark
        playIcon.image = UIImage(systemName: "play.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .regular, scale: .small))
        playIcon.contentMode = .center
        playIcon.setContentHuggingPriority(.required, for: .horizontal)

        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        progressBackground.translatesAutoresizingMaskIntoConstraints = false
        progressBackground.backgroundColor = .quaternaryLabel
        progressBackground.layer.cornerRadius = Self.barSize.height / 2
        progressBackground.layer.cornerCurve = .continuous
        progressBackground.clipsToBounds = true
        progressContainer.addSubview(progressBackground)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        // Square trailing end: only the track's clip rounds the fill.
        progressBackground.addSubview(progressFill)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 20, weight: .medium)
        infoLabel.numberOfLines = 1
        setFocused(false)

        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(playIcon)
        stack.addArrangedSubview(progressContainer)
        stack.addArrangedSubview(infoLabel)
        addSubview(stack)

        progressFillWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Width at 999: TVCardView lays its content host out at width 0
            // on the first pass; a required width there spams constraint breaks.
            progressContainer.widthAnchor.constraint(equalToConstant: Self.barSize.width).withPriority(999),
            progressContainer.heightAnchor.constraint(equalToConstant: Self.barSize.height),
            progressBackground.topAnchor.constraint(equalTo: progressContainer.topAnchor),
            progressBackground.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor),
            progressBackground.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            progressBackground.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),

            progressFill.leadingAnchor.constraint(equalTo: progressBackground.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressBackground.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressBackground.bottomAnchor),
            progressFillWidthConstraint
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let barSize = CGSize(width: 34, height: 6)

    /// Glyph, label and bar fill go full white on the focused card. Call it
    /// inside the focus animation coordinator.
    func setFocused(_ focused: Bool) {
        let text = UIColor.white.withAlphaComponent(focused ? 1 : 0.5)
        playIcon.tintColor = text
        infoLabel.textColor = text
        progressFill.backgroundColor = focused ? .white : .tertiaryLabel
    }

    func configure(item: PlexMetadata) {
        // Show progress capsule only when 0 < watchProgress < 1
        // (mirrors SwiftUI's `if let progress, progress > 0 && progress < 1`).
        let p = item.watchProgress ?? 0
        var parts: [String] = []
        if item.type == "episode" {
            let season = item.parentIndex ?? 0
            let episode = item.index ?? 0
            parts.append("S\(season), E\(episode)")
        }
        if let remaining = item.remainingTimeFormatted {
            parts.append(remaining)
        } else if let duration = item.durationFormatted {
            parts.append(duration)
        }
        apply(progressFraction: p > 0 && p < 1 ? p : nil,
              infoText: parts.joined(separator: " \u{00B7} "))
    }

    /// MediaItem path. `runtime` and `viewOffset` are both in seconds.
    func configure(item: MediaItem) {
        let offset = item.userState.viewOffset          // seconds
        let runtime = item.runtime                      // seconds; nil for shows
        let fraction: Double
        if let rt = runtime, rt > 0 {
            fraction = offset / rt
        } else {
            fraction = 0
        }

        var parts: [String] = []
        if let s = item.seasonNumber, let e = item.episodeNumber {
            parts.append("S\(s), E\(e)")
        }
        // Prefer remaining time; fall back to total runtime. Both in seconds.
        // Sub-minute values are suppressed (matches durationFormatted / remainingTimeFormatted
        // behavior: guard totalMinutes > 0 else return nil).
        if let rt = runtime {
            let remaining = max(0, rt - offset)
            let timeString: String?
            if remaining > 0 && fraction > 0 && fraction < 1 {
                timeString = formatSeconds(remaining)
            } else {
                timeString = formatSeconds(rt)
            }
            if let timeString {
                parts.append(timeString)
            }
        }
        apply(progressFraction: fraction > 0 && fraction < 1 ? fraction : nil,
              infoText: parts.joined(separator: " \u{00B7} "))
    }

    func reset() {
        playIcon.isHidden = true
        progressContainer.isHidden = true
        progressFillWidthConstraint.constant = 0
        infoLabel.text = nil
        setFocused(false)
    }

    // MARK: - Shared renderer

    /// Single sink for both configure paths. Keeps the two callers identical
    /// in visual output. The play icon follows the progress capsule: an
    /// item with no real play progress ("up next" episodes etc.) shows
    /// neither — just the info text.
    private func apply(progressFraction: Double?, infoText: String) {
        if let p = progressFraction {
            playIcon.isHidden = false
            progressContainer.isHidden = false
            // Apple draws any progress as at least 2 percent.
            progressFillWidthConstraint.constant = Self.barSize.width * CGFloat(max(p, 0.02))
        } else {
            playIcon.isHidden = true
            progressContainer.isHidden = true
            progressFillWidthConstraint.constant = 0
        }
        infoLabel.text = infoText
    }

    // MARK: - Formatters

    /// "Xh Ym" or "Ym", or nil for sub-minute values. Matches the
    /// guard `totalMinutes > 0` in `durationFormatted` / `remainingTimeFormatted`.
    /// Takes seconds (MediaItem uses seconds; Plex path converts upstream via
    /// item.remainingTimeFormatted).
    private func formatSeconds(_ seconds: TimeInterval) -> String? {
        let totalMinutes = Int(seconds) / 60
        guard totalMinutes > 0 else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Bottom info blur

/// Bottom legibility band — the ATV+ treatment (see Docs/atv_ref/
/// below_home_hero_ref.JPG): the bottom quarter of the card carries a REAL
/// blur with a soft gradient top edge, so the info bar reads over any
/// artwork. This replaced the old dark scrim (MediaBottomGradient), which
/// read as a bad shadow. Shared by ContinueWatchingCell (always on) and
/// PosterCell (shown only while in-progress, toggled with the info bar).
@MainActor
final class BottomInfoBlurView: UIView {

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let fadeMask = CAGradientLayer()

    /// How opaque the blur band is. < 1 lets the sharp artwork read through by
    /// (1 - this), so the info stays legible without the blur obscuring the
    /// picture. Deterministic — replaced the paused-animator "fractionComplete"
    /// scrub, which silently reset to FULL blur on window attach (device builds
    /// rendered max-strength regardless). Plain alpha has no such lifecycle.
    private let blurStrength: CGFloat = 0.85

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        // Clip within our OWN bounds — the supported clipping boundary for a
        // UIVisualEffectView is its superview — and round the bottom corners
        // to hug the card's 16pt shape. Without this the backdrop rendered
        // past the poster's rounded edge on PosterCell.
        clipsToBounds = true
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        blurView.alpha = blurStrength
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Soft top edge: the band fades in over its top ~45%. The mask lives on
        // the CONTAINER (masking a UIVisualEffectView directly is unsupported;
        // masking its superview is the standard pattern).
        fadeMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor
        ]
        fadeMask.locations = [0, 0.45, 1]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = fadeMask
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        CATransaction.commit()
    }
}

/// Apple-style "watched" indicator: the rewatch arrow
/// (`arrow.trianglehead.counterclockwise`) shown at the BOTTOM-LEFT of a
/// poster/thumb — the same slot the play icon + progress bar occupy for in-progress
/// items. Replaces the old top-right corner checkmark. Watched and in-progress are
/// mutually exclusive, so the two never collide in that corner.
///
/// Carries a soft shadow so it stays legible on bright artwork without a scrim.
@MainActor
final class WatchedGlyphView: UIImageView {

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        contentMode = .scaleAspectFit
        tintColor = .white
        // `arrow.trianglehead.counterclockwise` is SF Symbols 6 (present on this
        // tvOS version — see SettingsDescriptors). Fall back defensively.
        let symbol = UIImage(systemName: "arrow.trianglehead.counterclockwise")
            ?? UIImage(systemName: "arrow.counterclockwise")
        image = symbol?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError() }
}

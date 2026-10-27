// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PosterCaptionView.swift
//  Rivulet
//
//  The title and year under a poster (Settings → Appearance → Show Titles
//  Under Posters, on by default): Home rows, library grids, the Watchlist and
//  the detail page's poster rows. One line each, the title truncated. Sits
//  under the lockup FRAME, not the resting artwork, so a focused poster grows
//  into its frame without covering it. Rows and grids add
//  `MediaRowMetrics.posterCaptionHeight` to their tile height to make room.
//

import UIKit

final class PosterCaptionView: UIStackView {
    static let titleFont = UIFont.systemFont(ofSize: 23, weight: .semibold)
    static let detailFont = UIFont.systemFont(ofSize: 19, weight: .medium)
    static let topGap: CGFloat = 10
    static let lineGap: CGFloat = 2
    /// Gap, title line, detail line.
    static let height: CGFloat = topGap + ceil(titleFont.lineHeight) + lineGap + ceil(detailFont.lineHeight)

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    /// False where the caption is the only title a tile has (Continue
    /// Watching): it then shows whatever Show Titles Under Posters says.
    var followsTitleSetting = true

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Self.lineGap
        alignment = .fill
        isUserInteractionEnabled = false
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = Self.detailFont
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        addArrangedSubview(titleLabel)
        addArrangedSubview(detailLabel)
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// nil hides the caption (the setting is off, or a music tile).
    func configure(title: String?, year: Int?) {
        configure(title: title, detail: year.map(String.init))
    }

    /// Any second line: a year, or an episode's "S1 · E3".
    func configure(title: String?, detail: String?) {
        isHidden = title == nil || (followsTitleSetting && !MediaRowMetrics.showsPosterTitles)
        titleLabel.text = title
        detailLabel.text = detail ?? " "
    }

    /// Replaces the second line only (Search's "1984 · Movie").
    func setDetail(_ detail: String?) {
        detailLabel.text = detail ?? " "
    }

    /// Continue Watching's caption: the title (an episode: its show) over the
    /// Play button's own title (`EpisodePicker.playTitle`), "Resume S5 · E3 ·
    /// 12 min left", "Play S5 · E3", "Resume · 42 min left". A movie with no
    /// resume point shows its year instead of a bare "Play".
    static func continueWatchingText(title: String, year: Int?, show: String?, season: Int?, episode: Int?,
                                     offsetSeconds: TimeInterval, runtimeSeconds: TimeInterval?)
        -> (title: String, detail: String?) {
        let resumes = WatchProgressPolicy.hasResumePoint(offsetSeconds: offsetSeconds, runtimeSeconds: runtimeSeconds)
        let line = EpisodePicker.playTitle(
            resumes: resumes, watched: false, season: season, episode: episode,
            timeLeft: ResumeText.timeLeft(offsetSeconds: offsetSeconds, runtimeSeconds: runtimeSeconds))
        if let show, season != nil, episode != nil { return (show, line) }
        return (title, resumes ? line : year.map(String.init))
    }

    /// Pin under `frameView` (the lockup frame), inset to its artwork.
    func pin(below frameView: UIView, artInset: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: Self.topGap),
            leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: artInset),
            trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -artInset),
        ])
    }
}

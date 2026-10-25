// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AboutInfoCells.swift
//  Rivulet
//
//  The two static info blocks at the bottom of the UIKit expanded detail,
//  matching the Apple TV+ show-detail reference (Docs/atv_ref/carousel_details_ref_about
//  + _information):
//
//   - AboutCollectionCell  — "About" header + two cards: left = title / genres /
//     synopsis, right = the content-rating block.
//   - InfoColumnsCollectionCell — three columns: Information / Languages /
//     Accessibility, the latter two derived from the item's media streams.
//
//  Both are single full-width cells in the below-fold compositional collection.
//  Neither cell is focusable: each hosts focusable cards, which is what the
//  focus-driven below-fold (FocusScrollControlledCollectionView) scrolls to.
//

import UIKit

// MARK: - About

final class AboutCollectionCell: UICollectionViewCell {
    static let reuseID = "AboutCollectionCell"

    private let header = sectionHeaderLabel("About")
    // Both cards are focusable controls: select the synopsis → description popup;
    // select the advisory → content-rating popup.
    private let leftCard = AboutCardControl()
    private let titleLabel = UILabel()
    private let genresLabel = UILabel()
    private let synopsisLabel = UILabel()

    // Right card = Common Sense Media advisory (inline: age + seal + one-liner;
    // full topic dots + paragraph live in the popup), content-rating fallback.
    private let rightCard = AboutCardControl()

    /// Set by the cell provider; the cell forwards the current data on select.
    var onSelectSynopsis: ((MediaItemDetail) -> Void)?
    var onSelectAdvisory: ((ContentAdvisory) -> Void)?
    private var currentDetail: MediaItemDetail?
    private let advisoryStack = UIStackView()
    private let ageLabel = UILabel()
    private let sealRow = UIStackView()
    private let sealIcon = UIImageView()
    private let sealLabel = UILabel()
    private let oneLinerLabel = UILabel()
    private let topicsStack = UIStackView()
    private let paragraphLabel = UILabel()
    private let fallbackCaption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        for card in [leftCard, rightCard] {
            card.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(card)
        }
        leftCard.onSelect = { [weak self] in
            guard let self, let d = self.currentDetail, !(d.item.overview ?? "").isEmpty else { return }
            self.onSelectSynopsis?(d)
        }
        rightCard.onSelect = { [weak self] in
            guard let self, let a = self.currentDetail?.contentAdvisory, a.hasAny else { return }
            self.onSelectAdvisory?(a)
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 36, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        leftCard.addSubview(titleLabel)

        genresLabel.translatesAutoresizingMaskIntoConstraints = false
        genresLabel.font = .systemFont(ofSize: 23, weight: .medium)
        genresLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        genresLabel.numberOfLines = 1
        leftCard.addSubview(genresLabel)

        synopsisLabel.translatesAutoresizingMaskIntoConstraints = false
        synopsisLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        synopsisLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        synopsisLabel.numberOfLines = 6
        leftCard.addSubview(synopsisLabel)

        // Advisory vertical stack.
        advisoryStack.translatesAutoresizingMaskIntoConstraints = false
        advisoryStack.axis = .vertical
        advisoryStack.alignment = .leading
        advisoryStack.spacing = 12
        rightCard.addSubview(advisoryStack)

        ageLabel.font = .systemFont(ofSize: 58, weight: .bold)
        ageLabel.textColor = .white

        sealIcon.image = UIImage(systemName: "checkmark.circle.fill")
        sealIcon.tintColor = .systemGreen
        sealIcon.contentMode = .scaleAspectFit
        sealIcon.setContentHuggingPriority(.required, for: .horizontal)
        sealLabel.font = .systemFont(ofSize: 21, weight: .bold)
        sealLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        sealLabel.text = "Common Sense"
        sealRow.axis = .horizontal
        sealRow.alignment = .center
        sealRow.spacing = 6
        sealRow.addArrangedSubview(sealIcon)
        sealRow.addArrangedSubview(sealLabel)

        oneLinerLabel.font = .systemFont(ofSize: 23, weight: .bold)
        oneLinerLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        oneLinerLabel.numberOfLines = 4

        topicsStack.axis = .vertical
        topicsStack.alignment = .fill
        topicsStack.spacing = 8

        paragraphLabel.font = .systemFont(ofSize: 17, weight: .regular)
        paragraphLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        paragraphLabel.numberOfLines = 5   // teaser; full text would overflow the card

        fallbackCaption.font = .systemFont(ofSize: 17, weight: .regular)
        fallbackCaption.textColor = UIColor.white.withAlphaComponent(0.7)
        fallbackCaption.numberOfLines = 2

        for v in [ageLabel, sealRow, oneLinerLabel, topicsStack, paragraphLabel, fallbackCaption] {
            advisoryStack.addArrangedSubview(v)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),

            leftCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            leftCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // On the six-column grid: the synopsis spans two columns, the
            // advisory one.
            leftCard.widthAnchor.constraint(equalToConstant: MediaRowMetrics.gridWidth(columns: 6, span: 2)),

            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: MediaRowMetrics.tileGap),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),
            rightCard.widthAnchor.constraint(equalToConstant: MediaRowMetrics.gridWidth(columns: 6)),

            titleLabel.topAnchor.constraint(equalTo: leftCard.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leftCard.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: -24),

            genresLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            genresLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            genresLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            synopsisLabel.topAnchor.constraint(equalTo: genresLabel.bottomAnchor, constant: 14),
            synopsisLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            synopsisLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            advisoryStack.topAnchor.constraint(equalTo: rightCard.topAnchor, constant: 22),
            advisoryStack.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 24),
            advisoryStack.trailingAnchor.constraint(equalTo: rightCard.trailingAnchor, constant: -24),
            advisoryStack.bottomAnchor.constraint(lessThanOrEqualTo: rightCard.bottomAnchor, constant: -22),

            sealRow.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            oneLinerLabel.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            topicsStack.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            paragraphLabel.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            fallbackCaption.widthAnchor.constraint(equalTo: advisoryStack.widthAnchor),
            sealIcon.heightAnchor.constraint(equalToConstant: 24),
            sealIcon.widthAnchor.constraint(equalToConstant: 24),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) {
        currentDetail = detail
        titleLabel.text = detail.item.title
        genresLabel.text = detail.genres.prefix(3).joined(separator: ", ")
        genresLabel.isHidden = detail.genres.isEmpty
        synopsisLabel.text = detail.item.overview

        let advisory = detail.contentAdvisory
        if let a = advisory, a.hasAny {
            // Inline = compact: age + seal + one-line description. The topic dots
            // and full text live in the click-to-open popup (ATV+ pattern).
            ageLabel.text = a.ageRating ?? detail.contentRating ?? "NR"
            sealRow.isHidden = false
            oneLinerLabel.text = a.oneLiner
            oneLinerLabel.isHidden = (a.oneLiner ?? "").isEmpty
            fallbackCaption.isHidden = true
        } else {
            // Fallback: content rating + numeric score (no CSM available).
            ageLabel.text = detail.contentRating ?? "NR"
            sealRow.isHidden = true
            oneLinerLabel.isHidden = true
            if let rating = detail.rating {
                fallbackCaption.text = "Rated · " + rating.summary
            } else {
                fallbackCaption.text = "Rated"
            }
            fallbackCaption.isHidden = false
        }
        // Topics + paragraph are popup-only; never shown inline.
        topicsStack.isHidden = true
        paragraphLabel.isHidden = true

        // Selectability: synopsis is clickable when there's an overview; advisory
        // when there's rich CSM (topics/paragraph worth a popup).
        leftCard.selectable = !(detail.item.overview ?? "").isEmpty
        rightCard.selectable = advisory?.hasRichDetail ?? false
    }
    // Focus lives on the two cards (AboutCardControl), not the cell itself.
    override var canBecomeFocused: Bool { false }
}

// MARK: - Information / Languages / Accessibility columns

final class InfoColumnsCollectionCell: UICollectionViewCell {
    static let reuseID = "InfoColumnsCollectionCell"

    private let columns = InfoColumnsView(style: .footer)
    private var detail: MediaItemDetail?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The cell spans the collection edge to edge, so its own fill is the band.
        contentView.backgroundColor = UIColor(white: 0, alpha: 0.2)
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.onSelect = { [weak self] in self?.presentFullInfo() }
        contentView.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.topInset),
            // The cell spans the collection, which overhangs the screen's left
            // edge when expanded: the rows' own leading rests it on the margin.
            columns.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: BelowFoldCollectionView.rowLeading),
            columns.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -PreviewCarouselGeometry.expandedChromeInset),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    /// 14 puts the 38 pt header's baseline 50 below the band top.
    private static let topInset: CGFloat = 14
    private static let bottomInset: CGFloat = 56

    /// Band height that fits `detail`'s tallest column in a row `columnsWidth` wide.
    static func height(for detail: MediaItemDetail, columnsWidth: CGFloat) -> CGFloat {
        let sizing = InfoColumnsView(style: .footer)
        sizing.configure(detail: detail)
        let fitted = sizing.systemLayoutSizeFitting(
            CGSize(width: columnsWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return topInset + fitted.height.rounded(.up) + bottomInset
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) {
        self.detail = detail
        columns.configure(detail: detail)
    }

    /// Select on a column opens the same full-info popup as the hero Info button.
    private func presentFullInfo() {
        guard let detail, var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let popup = InfoPopupViewController(content: InfoPopupContent.fullInfo(detail: detail),
                                            width: 900, height: 900, scrollable: true)
        top.present(popup, animated: true)
    }
}

/// Standalone Information / Languages / Accessibility columns. Reused by the
/// carousel below-fold cell above AND the episode detail page's below-fold.
final class InfoColumnsView: UIView {
    private let information = InfoColumnView()
    private let languages = InfoColumnView()
    private let accessibility = InfoColumnView()
    private let row = UIStackView()
    private let style: InfoColumnView.Style
    /// Select on a column's card (footer style only).
    var onSelect: (() -> Void)?

    init(style: InfoColumnView.Style = .standard) {
        self.style = style
        super.init(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = style.columnGap
        addSubview(row)
        [information, languages, accessibility].forEach { column in
            column.onSelect = { [weak self] in self?.onSelect?() }
            row.addArrangedSubview(column)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(detail: MediaItemDetail) {
        // Information
        var info: [(String, String)] = []
        if let y = detail.item.year { info.append(("Released", "\(y)")) }
        if let seasons = detail.seasonCount, seasons > 0 {
            info.append(("Seasons", seasons == 1 ? "1 Season" : "\(seasons) Seasons"))
        }
        if let runtime = detail.item.runtime, runtime > 0 { info.append(("Run Time", Self.runtime(runtime))) }
        if let r = detail.contentRating, !r.isEmpty { info.append(("Rated", r)) }
        if !detail.genres.isEmpty { info.append(("Genres", detail.genres.prefix(4).joined(separator: ", "))) }
        if !detail.studios.isEmpty { info.append(("Studio", detail.studios.prefix(2).joined(separator: ", "))) }
        information.configure(title: "Information", rows: info, style: style)

        // Languages — from the first media source's tracks.
        let source = detail.primarySource
        var langs: [(String, String)] = []
        if let audio = source?.audioTracks, !audio.isEmpty {
            let names = uniqueOrdered(audio.compactMap { Self.languageName($0.language) })
            if !names.isEmpty { langs.append(("Audio", names.joined(separator: ", "))) }
        }
        if let subs = source?.subtitleTracks, !subs.isEmpty {
            let names = uniqueOrdered(subs.compactMap { t -> String? in
                guard let n = Self.languageName(t.language) else { return nil }
                return t.isHearingImpaired ? "\(n) (SDH)" : n
            })
            if !names.isEmpty { langs.append(("Subtitles", names.joined(separator: ", "))) }
        }
        if langs.isEmpty { langs.append(("Audio", "Unknown")) }
        languages.configure(title: "Languages", rows: langs, style: style)

        // Accessibility — SDH / AD presence from the tracks.
        var access: [(String, String)] = []
        let hasSDH = source?.subtitleTracks.contains { $0.isHearingImpaired } ?? false
        let hasAD = source?.audioTracks.contains {
            ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri")
        } ?? false
        if hasSDH { access.append(("SDH", "Subtitles for the deaf and hard of hearing are available.")) }
        if hasAD { access.append(("AD", "Audio descriptions are available.")) }
        if access.isEmpty { access.append(("", "No accessibility features detected.")) }
        accessibility.configure(title: "Accessibility", rows: access, style: style)
    }

    private func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for v in values where !seen.contains(v) { seen.insert(v); out.append(v) }
        return out
    }

    private static func runtime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded()); let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m) min"
    }

    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        if let name = Locale.current.localizedString(forLanguageCode: code) { return name.capitalized }
        return code.uppercased()
    }
}

/// One labelled column (header + stacked label/value pairs). Reused by the
/// 3-column below-fold AND the vertically-stacked Info popup.
final class InfoColumnView: UIView {
    /// Type and spacing for one use of the column. `standard` is the Info popup
    /// and the episode page; `footer` is the movie/show page's bottom band.
    nonisolated struct Style {
        var headerFont = UIFont.systemFont(ofSize: 40, weight: .bold)
        var headerColor = UIColor.white
        var headerGap: CGFloat = 20
        var labelFont = UIFont.systemFont(ofSize: 21, weight: .semibold)
        var labelColor = UIColor.white.withAlphaComponent(0.5)
        var valueFont = UIFont.systemFont(ofSize: 26, weight: .semibold)
        var valueColor = UIColor.white.withAlphaComponent(0.9)
        var valueLines = 0
        var valueLineSpacing: CGFloat = 0
        var pairGap: CGFloat = 2
        var rowGap: CGFloat = 14
        var columnGap: CGFloat = 48
        /// Wraps the rows (not the header) in a focusable card.
        var focusCard = false

        static let standard = Style()
        static let footer = Style(
            headerFont: .systemFont(ofSize: 38, weight: .bold),
            headerColor: UIColor.white.withAlphaComponent(0.7),
            headerGap: 30,
            labelFont: .systemFont(ofSize: 23, weight: .medium),
            labelColor: UIColor.white.withAlphaComponent(0.3),
            valueFont: .systemFont(ofSize: 23, weight: .medium),
            valueColor: UIColor.white.withAlphaComponent(0.7),
            valueLines: 5,
            valueLineSpacing: 2,
            pairGap: 9,
            rowGap: 30,
            columnGap: 50,
            focusCard: true)
    }

    /// How far the focus card reaches past the rows on every side.
    private static let cardOutset: CGFloat = 15

    private let stack = UIStackView()
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    /// Select on the rows card (footer style only).
    var onSelect: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        addSubview(stack)
        // Bottom pinned with `=` at high (not required) priority so the column
        // HUGS its content when nothing else drives its height (the vertically-
        // stacked Info popup). In the below-fold's horizontal `.fill` row, the
        // required equal-height stretch outranks this and still wins.
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        stackLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stackLeading,
            stackTrailing,
            bottom,
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, rows: [(String, String)], style: Style = .standard) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = UILabel()
        header.font = style.headerFont
        header.textColor = style.headerColor
        header.text = title

        // The card overhangs the column, so the stack does too and the header
        // is inset back to the column edge.
        let outset = style.focusCard ? Self.cardOutset : 0
        stackLeading.constant = -outset
        stackTrailing.constant = outset

        let rowStack: UIStackView
        if style.focusCard {
            let headerBox = Self.inset(header, by: .init(top: 0, left: outset, bottom: 0, right: outset))
            rowStack = UIStackView()
            rowStack.axis = .vertical
            let card = AboutCardControl()
            card.restAlpha = 0
            card.layer.cornerRadius = 24
            card.onSelect = { [weak self] in self?.onSelect?() }
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(rowStack)
            NSLayoutConstraint.activate([
                rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: outset),
                rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: outset),
                rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -outset),
                rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -outset),
            ])
            stack.addArrangedSubview(headerBox)
            stack.setCustomSpacing(style.headerGap - outset, after: headerBox)
            stack.addArrangedSubview(card)
        } else {
            rowStack = stack
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(style.headerGap, after: header)
        }
        rowStack.spacing = style.rowGap

        for (label, value) in rows {
            let pair = UIStackView()
            pair.axis = .vertical
            pair.spacing = style.pairGap
            if !label.isEmpty {
                let l = UILabel()
                l.font = style.labelFont
                l.textColor = style.labelColor
                l.text = label
                pair.addArrangedSubview(l)
            }
            let v = UILabel()
            v.font = style.valueFont
            v.textColor = style.valueColor
            v.numberOfLines = style.valueLines
            if style.valueLineSpacing > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = style.valueLineSpacing
                paragraph.lineBreakMode = .byTruncatingTail
                v.attributedText = NSAttributedString(string: value, attributes: [.paragraphStyle: paragraph])
            } else {
                v.text = value
            }
            pair.addArrangedSubview(v)
            rowStack.addArrangedSubview(pair)
        }
    }

    private static func inset(_ view: UIView, by insets: UIEdgeInsets) -> UIView {
        let box = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -insets.bottom),
        ])
        return box
    }
}

// MARK: - Shared

private func sectionHeaderLabel(_ text: String) -> UILabel {
    let l = UILabel()
    l.font = .systemFont(ofSize: 30, weight: .semibold)
    l.textColor = .white
    l.text = text
    return l
}

// MARK: - Focusable About card

/// A focusable About card (synopsis or advisory). Selecting it opens the matching
/// popup. Focus appearance = subtle brighten + scale (matches the glass style).
final class AboutCardControl: UIControl {
    var onSelect: (() -> Void)?
    /// Gates focus/selection — e.g. the advisory card only when CSM is present.
    var selectable: Bool = true {
        didSet { if selectable != oldValue { setNeedsFocusUpdate() } }
    }
    override var canBecomeFocused: Bool { selectable }
    /// Fill alpha when not focused. 0 = no card at rest (the footer columns).
    var restAlpha: CGFloat = 0.06 {
        didSet { backgroundColor = UIColor(white: 1, alpha: restAlpha) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: restAlpha)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        addTarget(self, action: #selector(fire), for: .primaryActionTriggered)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onSelect?() }

    // primaryActionTriggered is unreliable for a bare UIControl on tvOS; the
    // remote Select press is delivered to the FOCUSED view's press handlers, so
    // handle it here directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            onSelect?()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = (context.nextFocusedView === self)
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.backgroundColor = UIColor(white: 1, alpha: focused ? 0.14 : self.restAlpha)
            self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
    }
}

// MARK: - Where to Watch (metadata-only items)

/// TMDB watch/providers for a title with no playback-capable provider:
/// Stream / Rent / Buy rows of provider logos, plus the text credit TMDB's
/// terms require for JustWatch-sourced data. Not focusable — like
/// AboutCollectionCell, it's a static info block the focus-driven below-fold
/// scrolls PAST rather than into (`BelowFoldCollectionView` keeps it in view
/// on the way past, see `FocusScrollControlledCollectionView.staticSections`).
/// Its height is measured from its rows, so the section never clips or
/// overlaps the one below it.
final class WhereToWatchCollectionCell: UICollectionViewCell {
    static let reuseID = "WhereToWatchCollectionCell"

    private enum Metrics {
        static let headerFont = UIFont.systemFont(ofSize: 30, weight: .semibold)
        static let rowTitleFont = UIFont.systemFont(ofSize: 21, weight: .semibold)
        static let attributionFont = UIFont.systemFont(ofSize: 17, weight: .regular)
        static let headerGap: CGFloat = 24
        static let rowGap: CGFloat = 32
        static let rowTitleGap: CGFloat = 12
        static let attributionGap: CGFloat = 28
        /// Logos per row: a static block, not a second scroller.
        static let maxLogos = 8
    }
    private static let groups: [(title: String, kind: MediaWatchOption.Kind)] = [
        ("Stream", .stream), ("Rent", .rent), ("Buy", .buy)
    ]

    private let header = sectionHeaderLabel("Where to Watch")
    private let rowsStack = UIStackView()
    private let attributionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.axis = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = Metrics.rowGap
        contentView.addSubview(rowsStack)

        // TMDB's terms require this credit whenever watch/providers data is
        // shown — see Docs/RIVULET_PLAYER.md-adjacent TMDB usage notes.
        attributionLabel.translatesAutoresizingMaskIntoConstraints = false
        attributionLabel.font = Metrics.attributionFont
        attributionLabel.textColor = UIColor.white.withAlphaComponent(0.4)
        attributionLabel.text = "Streaming, rental, and purchase data provided by JustWatch"
        attributionLabel.numberOfLines = 1
        contentView.addSubview(attributionLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),

            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.headerGap),
            rowsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),

            attributionLabel.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: Metrics.attributionGap),
            attributionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The cell's full height for `availability`: header, one row per
    /// non-empty group, the attribution line.
    static func height(for availability: MediaWatchAvailability) -> CGFloat {
        let rows = CGFloat(groups.filter { group in availability.options.contains { $0.kind == group.kind } }.count)
        let rowHeight = ceil(Metrics.rowTitleFont.lineHeight) + Metrics.rowTitleGap + WatchProviderChip.height
        return ceil(Metrics.headerFont.lineHeight) + Metrics.headerGap
            + rows * rowHeight + max(0, rows - 1) * Metrics.rowGap
            + Metrics.attributionGap + ceil(Metrics.attributionFont.lineHeight)
    }

    func configure(availability: MediaWatchAvailability) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in Self.groups {
            let options = availability.options.filter { $0.kind == group.kind }
            guard !options.isEmpty else { continue }
            rowsStack.addArrangedSubview(Self.makeRow(title: group.title, options: options))
        }
    }

    private static func makeRow(title: String, options: [MediaWatchOption]) -> UIView {
        let container = UIView()

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Metrics.rowTitleFont
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        label.text = title
        container.addSubview(label)

        let logos = UIStackView()
        logos.translatesAutoresizingMaskIntoConstraints = false
        logos.axis = .horizontal
        logos.alignment = .top
        logos.spacing = WatchProviderChip.gap
        for option in options.prefix(Metrics.maxLogos) {
            logos.addArrangedSubview(WatchProviderChip(option: option))
        }
        container.addSubview(logos)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            logos.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Metrics.rowTitleGap),
            logos.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            logos.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            logos.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // Static info block — not a focus stop (matches AboutCollectionCell).
    override var canBecomeFocused: Bool { false }
}

/// One provider's logo chip (rounded square) over its name, used by the
/// Where to Watch rows. The chip's own width is its name's column, so a
/// long name wraps to two lines and truncates inside it instead of running
/// under the next logo. `MediaWatchOption.logoURL` is already fully-qualified
/// by `TMDBMediaMapper`.
private final class WatchProviderChip: UIView {
    private static let logoSize: CGFloat = 64
    private static let columnWidth: CGFloat = 112
    private static let nameGap: CGFloat = 8
    private static let nameFont = UIFont.systemFont(ofSize: 15, weight: .medium)
    /// Space between two chips' name columns.
    static let gap: CGFloat = 20
    static let height: CGFloat = logoSize + nameGap + ceil(nameFont.lineHeight * 2)

    private let imageContainer = UIView()
    private let imageView = UIImageView()
    private let nameLabel = UILabel()

    init(option: MediaWatchOption) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.backgroundColor = UIColor(white: 0.15, alpha: 1)
        imageContainer.layer.cornerRadius = 14
        imageContainer.layer.cornerCurve = .continuous
        imageContainer.clipsToBounds = true
        addSubview(imageContainer)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageContainer.addSubview(imageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Self.nameFont
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.text = option.providerName
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.columnWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            imageContainer.topAnchor.constraint(equalTo: topAnchor),
            imageContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageContainer.widthAnchor.constraint(equalToConstant: Self.logoSize),
            imageContainer.heightAnchor.constraint(equalToConstant: Self.logoSize),

            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor, constant: 6),
            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor, constant: -6),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: -6),

            nameLabel.topAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: Self.nameGap),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        guard let url = option.logoURL else { return }
        imageView.image = ImageCacheManager.shared.cachedImage(for: url)
        guard imageView.image == nil else { return }
        Task { [weak imageView] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run { imageView?.image = image }
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - On Your Servers (metadata-only items)

/// Every copy of the title on a server this account can reach (owned or
/// shared, the main server included, a server's 1080p and 4K copies apart):
/// one focusable card each, which switches the page to that copy, or a
/// static status line while checking and when none does.
final class ServerAvailabilityCollectionCell: UICollectionViewCell {
    static let reuseID = "ServerAvailabilityCollectionCell"

    private enum Metrics {
        static let headerGap: CGFloat = 16
        static let cardWidth: CGFloat = 380
        static let cardHeight: CGFloat = 104
        static let cardGap: CGFloat = MediaRowMetrics.tileGap
        /// Room for the focused card's scale inside the row's scroller.
        static let focusRoom: CGFloat = 12
    }
    /// The cell's height in every state (the cards are the tallest).
    static let height: CGFloat = ceil(UIFont.systemFont(ofSize: 30, weight: .semibold).lineHeight)
        + Metrics.headerGap + Metrics.cardHeight + Metrics.focusRoom * 2

    private let header = sectionHeaderLabel("On Your Servers")
    private let statusLabel = UILabel()
    private let cardsStack = UIStackView()
    /// Every copy gets a card (a server can hold a 1080p and a 4K one), so
    /// the row scrolls sideways as focus moves along it.
    private let cardsScroller = UIScrollView()

    /// Select on a card: play that server's copy.
    var onSelectCopy: ((ServerCopyEntry) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 25, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.numberOfLines = 1
        contentView.addSubview(statusLabel)

        cardsScroller.translatesAutoresizingMaskIntoConstraints = false
        cardsScroller.clipsToBounds = false
        cardsScroller.showsHorizontalScrollIndicator = false
        contentView.addSubview(cardsScroller)
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.axis = .horizontal
        cardsStack.spacing = Metrics.cardGap
        cardsScroller.addSubview(cardsStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),

            statusLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.headerGap),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),

            cardsScroller.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.headerGap - Metrics.focusRoom),
            cardsScroller.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardsScroller.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardsScroller.heightAnchor.constraint(equalToConstant: Metrics.cardHeight + Metrics.focusRoom * 2),

            cardsStack.topAnchor.constraint(equalTo: cardsScroller.contentLayoutGuide.topAnchor, constant: Metrics.focusRoom),
            cardsStack.leadingAnchor.constraint(equalTo: cardsScroller.contentLayoutGuide.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: cardsScroller.contentLayoutGuide.trailingAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: cardsScroller.contentLayoutGuide.bottomAnchor, constant: -Metrics.focusRoom),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(availability: ServerAvailability) {
        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch availability {
        case .checking:
            statusLabel.text = "Checking your servers…"
        case .notFound:
            statusLabel.text = "Not on your servers"
        case .found(let entries):
            statusLabel.text = nil
            for entry in entries {
                cardsStack.addArrangedSubview(makeCard(entry))
            }
        }
        statusLabel.isHidden = statusLabel.text == nil
        cardsScroller.contentOffset = .zero
    }

    private func makeCard(_ entry: ServerCopyEntry) -> UIView {
        let card = AboutCardControl()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.onSelect = { [weak self] in self?.onSelectCopy?(entry) }

        let icon = UIImageView(image: UIImage(systemName: "play.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = UILabel()
        name.font = .systemFont(ofSize: 27, weight: .semibold)
        name.textColor = .white
        name.text = entry.serverName

        let summary = UILabel()
        summary.font = .systemFont(ofSize: 20, weight: .medium)
        summary.textColor = UIColor.white.withAlphaComponent(0.6)
        summary.text = entry.summary
        summary.isHidden = entry.summary == nil

        let text = UIStackView(arrangedSubviews: [name, summary])
        text.translatesAutoresizingMaskIntoConstraints = false
        text.axis = .vertical
        text.spacing = 4
        card.addSubview(icon)
        card.addSubview(text)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Metrics.cardWidth),
            card.heightAnchor.constraint(equalToConstant: Metrics.cardHeight),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            text.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    // Not a focus stop itself: its cards are.
    override var canBecomeFocused: Bool { false }
}

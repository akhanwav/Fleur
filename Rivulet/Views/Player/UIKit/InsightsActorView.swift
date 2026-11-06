// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorView.swift
//  Rivulet
//
//  A cast member inside the Insights box, laid out like the Info card:
//  portrait, name and a four-line bio on the left, their ten most popular
//  titles on TMDB as a row of posters with names on the right. Select on the
//  bio spreads it across the box to read; Menu folds it back.
//

import UIKit

final class InsightsActorView: UIView {

    private enum Metrics {
        static let portrait = CGRect(x: 23, y: 23, width: 136, height: 204)
        static let textX: CGFloat = 199
        static let nameTop: CGFloat = 33
        static let bioTop: CGFloat = 80
        static let bioWidth: CGFloat = 600
        static let readingWidth: CGFloat = 1500
        static let postersLeading: CGFloat = 860
        static let posterGap: CGFloat = 20
        static let titleLimit = 10
    }

    private let person: MediaPerson
    /// Internal for tests: the loaded detail, once one has been applied.
    private(set) var detail: PersonDetail?

    private let portrait = UIImageView()
    private let bio = PlayerSummaryButton(text: "Loading…", lines: 4)
    private let posterScroll = UIScrollView()
    private let posterStack = UIStackView()
    private var bioWidth: NSLayoutConstraint?
    private var portraitTask: Task<Void, Never>?
    private var isReading = false

    init(person: MediaPerson) {
        self.person = person
        super.init(frame: .zero)

        portrait.contentMode = .scaleAspectFill
        portrait.clipsToBounds = true
        portrait.layer.cornerRadius = 25
        portrait.layer.cornerCurve = .continuous
        portrait.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        portrait.tintColor = UIColor.white.withAlphaComponent(0.35)
        portrait.image = UIImage(systemName: "person.fill")

        let name = UILabel()
        name.text = person.name
        name.font = .systemFont(ofSize: 31, weight: .bold)
        name.textColor = .white

        bio.onPress = { [weak self] in self?.setReading(!(self?.isReading ?? false)) }

        posterScroll.clipsToBounds = true
        posterScroll.showsHorizontalScrollIndicator = false
        // Room for a focused poster's growth at the ends.
        posterScroll.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        posterStack.axis = .horizontal
        posterStack.spacing = Metrics.posterGap
        posterStack.alignment = .center
        posterScroll.addSubview(posterStack)

        [portrait, name, bio, posterScroll, posterStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        [portrait, name, bio, posterScroll].forEach { addSubview($0) }
        let bioWidth = bio.textWidth.constraint(equalToConstant: Metrics.bioWidth)
        self.bioWidth = bioWidth
        NSLayoutConstraint.activate([
            portrait.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.portrait.minX),
            portrait.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.portrait.minY),
            portrait.widthAnchor.constraint(equalToConstant: Metrics.portrait.width),
            portrait.heightAnchor.constraint(equalToConstant: Metrics.portrait.height),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            name.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.nameTop),
            name.trailingAnchor.constraint(lessThanOrEqualTo: posterScroll.leadingAnchor, constant: -20),
            bio.textLeading.constraint(equalTo: leadingAnchor, constant: Metrics.textX),
            bio.textTop.constraint(equalTo: topAnchor, constant: Metrics.bioTop),
            bioWidth,
            posterScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.postersLeading),
            posterScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -23),
            posterScroll.topAnchor.constraint(equalTo: topAnchor),
            posterScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            posterStack.topAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.topAnchor),
            posterStack.bottomAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.bottomAnchor),
            posterStack.leadingAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.leadingAnchor),
            posterStack.trailingAnchor.constraint(equalTo: posterScroll.contentLayoutGuide.trailingAnchor),
            posterStack.heightAnchor.constraint(equalTo: posterScroll.frameLayoutGuide.heightAnchor),
        ])
        loadPortrait(person.imageURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { portraitTask?.cancel() }

    func populate(_ detail: PersonDetail) {
        self.detail = detail
        let text = detail.biography?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        bio.setText(text.isEmpty ? "No biography available." : text)
        if let url = detail.portraitURL, url != person.imageURL { loadPortrait(url) }
    }

    /// The posters: the person's titles, most popular on TMDB first.
    func showFilmography(_ entries: [FilmographyEntry]) {
        posterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in Self.topTitles(entries) {
            posterStack.addArrangedSubview(InsightsPosterCardView(item: entry.item))
        }
    }

    /// Internal for tests: the `limit` most popular titles, once each. Titles
    /// with no popularity (a person TMDB doesn't know) keep their order.
    static func topTitles(_ entries: [FilmographyEntry], limit: Int = Metrics.titleLimit) -> [FilmographyEntry] {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.key).inserted }
        let ranked = unique.enumerated().sorted { a, b in
            a.element.popularity != b.element.popularity ? a.element.popularity > b.element.popularity : a.offset < b.offset
        }
        return ranked.prefix(limit).map(\.element)
    }

    /// The load failed or found nothing: portrait and name stay, no posters.
    func showDetailsUnavailable() {
        bio.setText("No details available.")
    }

    /// Menu folds a reading bio back first.
    func handleMenuPress() -> Bool {
        guard isReading else { return false }
        setReading(false)
        return true
    }

    private func setReading(_ reading: Bool) {
        isReading = reading
        bioWidth?.constant = reading ? Metrics.readingWidth : Metrics.bioWidth
        bio.setShrinksToFit(reading)
        UIView.animate(withDuration: 0.25) {
            self.posterScroll.alpha = reading ? 0 : 1
            self.layoutIfNeeded()
        }
        posterScroll.isUserInteractionEnabled = !reading
    }

    private func loadPortrait(_ url: URL?) {
        guard let url else { return }
        portraitTask?.cancel()
        portraitTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, let image else { return }
            self.portrait.image = image
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [bio] }
}

/// One filmography title: a poster with its name and year under it. Focusable,
/// so focus moves across the row; Select does nothing yet.
private final class InsightsPosterCardView: UIView {

    private static let size = CGSize(width: 110, height: 165)
    private static let captionGap: CGFloat = 8
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let yearLabel = UILabel()
    private var imageTask: Task<Void, Never>?

    init(item: MediaItem) {
        super.init(frame: .zero)
        titleLabel.text = item.title
        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        yearLabel.text = item.year.map(String.init)
        yearLabel.font = .systemFont(ofSize: 15, weight: .regular)
        [titleLabel, yearLabel].forEach {
            $0.textAlignment = .center
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        applyFocus(false)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        imageView.tintColor = UIColor.white.withAlphaComponent(0.35)
        imageView.contentMode = .center
        imageView.image = UIImage(systemName: "film")
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.heightAnchor.constraint(equalToConstant: Self.size.height),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: Self.captionGap),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            yearLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            yearLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            yearLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            yearLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let url = item.artwork.poster {
            imageTask = Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard let self, !Task.isCancelled, let image else { return }
                self.imageView.contentMode = .scaleAspectFill
                self.imageView.image = image
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel() }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.applyFocus(focused)
        }
    }

    /// The poster grows and lifts, with a white rim; the caption brightens.
    private func applyFocus(_ focused: Bool) {
        transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
        imageView.layer.borderWidth = focused ? 3 : 0
        imageView.layer.borderColor = UIColor.white.cgColor
        titleLabel.textColor = UIColor.white.withAlphaComponent(focused ? 1 : 0.7)
        yearLabel.textColor = UIColor.white.withAlphaComponent(focused ? 0.8 : 0.45)
    }
}

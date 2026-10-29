//
//  EndCardOverlayView.swift
//  Rivulet
//
//  The end card: when a show's latest available episode ends, a glass panel
//  the size and place of the Up Next card slides in over the credits: "You're
//  all caught up on <show>", then "You May Also Like" over up to five posters,
//  and Back to Show. A focused poster's title shows under the row; selecting
//  it opens its page. Back closes the panel. It closes by itself after
//  `UniversalPlayerViewModel.endCardSeconds` unless the person moves on it.
//  Movies get no panel.
//
//  Like the Up Next card, the view IS the panel's footprint: the container
//  pins it to the trailing edge, so the credits stay visible beside it.
//

import UIKit

final class EndCardOverlayView: UIView {

    private enum Metrics {
        // The Up Next card's (`PostVideoOverlayView`).
        static let width: CGFloat = 640
        static let padding: CGFloat = 40
        static let cornerRadius: CGFloat = 40
        static let offscreen: CGFloat = 720
        static let posterGap: CGFloat = 14
    }

    /// A poster was selected.
    var onSelect: ((MediaItem) -> Void)?
    /// Back to Show.
    var onBackToShow: (() -> Void)?
    /// A focus move the person made: the panel stays up.
    var onUserFocusMove: (() -> Void)?

    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .clear))
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let headingLabel = UILabel()
    private let postersRow = UIStackView()
    /// The focused poster's title and year, under the row.
    private let focusedTitleLabel = UILabel()
    private let backButton = PostVideoButtonView(isPrimary: true)
    private var posters: [EndCardPosterView] = []
    private var hasShow = false

    init() {
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear
        transform = CGAffineTransform(translationX: Metrics.offscreen, y: 0)

        glass.contentView.backgroundColor = PlayerRailPanelView.glassWash
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Metrics.cornerRadius
        glass.layer.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        headingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        headingLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        focusedTitleLabel.font = .systemFont(ofSize: 20, weight: .medium)
        focusedTitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        focusedTitleLabel.text = " "

        postersRow.axis = .horizontal
        postersRow.spacing = Metrics.posterGap
        postersRow.distribution = .fillEqually
        postersRow.clipsToBounds = false

        backButton.configure(title: "Back to Show", systemImage: "chevron.backward")
        backButton.onTap = { [weak self] in self?.onBackToShow?() }
        backButton.onUserFocus = { [weak self] in self?.onUserFocusMove?() }

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .leading
        [titleLabel, headingLabel, postersRow, focusedTitleLabel, backButton].forEach(contentStack.addArrangedSubview)
        contentStack.setCustomSpacing(28, after: titleLabel)
        contentStack.setCustomSpacing(10, after: postersRow)
        contentStack.setCustomSpacing(24, after: focusedTitleLabel)

        [glass, contentStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let rowWidth = Metrics.width - 2 * Metrics.padding
        let posterWidth = (rowWidth - 4 * Metrics.posterGap) / 5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.padding),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
            titleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            focusedTitleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            postersRow.heightAnchor.constraint(equalToConstant: (posterWidth * 1.5).rounded()),
        ])
        postersRowWidth = postersRow.widthAnchor.constraint(equalToConstant: rowWidth)
        postersRowWidth?.isActive = true
    }

    private var postersRowWidth: NSLayoutConstraint?

    func configure(_ content: EndCardContent) {
        titleLabel.text = content.title
        headingLabel.text = "You May Also Like"
        hasShow = content.show != nil
        backButton.isHidden = !hasShow

        posters.forEach { $0.removeFromSuperview() }
        posters = content.related.prefix(5).map { item in
            let poster = EndCardPosterView(item: item)
            poster.onSelect = { [weak self] in self?.onSelect?(item) }
            poster.onFocus = { [weak self] focused, byUser in
                guard let self else { return }
                if focused { self.focusedTitleLabel.text = Self.caption(item) }
                if byUser { self.onUserFocusMove?() }
            }
            return poster
        }
        posters.forEach(postersRow.addArrangedSubview)
        // Fewer than five keep the five-across size, from the leading edge.
        let rowWidth = Metrics.width - 2 * Metrics.padding
        let posterWidth = (rowWidth - 4 * Metrics.posterGap) / 5
        postersRowWidth?.constant = CGFloat(posters.count) * posterWidth
            + CGFloat(max(posters.count - 1, 0)) * Metrics.posterGap
        let hasPosters = !posters.isEmpty
        headingLabel.isHidden = !hasPosters
        postersRow.isHidden = !hasPosters
        focusedTitleLabel.isHidden = !hasPosters
    }

    private static func caption(_ item: MediaItem) -> String {
        [item.title, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Slides in from the trailing edge, as the Up Next card does.
    func slideIn() {
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.transform = .identity
        }
    }

    /// Slides back off the edge, then removes it.
    func slideOut(completion: @escaping () -> Void) {
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseIn, animations: {
            self.transform = CGAffineTransform(translationX: Metrics.offscreen, y: 0)
        }, completion: { _ in
            self.removeFromSuperview()
            completion()
        })
    }

    // MARK: - Focus

    /// The panel lands on Back to Show, so a stray Select does not open
    /// another title; without it, on the first poster.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        hasShow ? [backButton] : (posters.first.map { [$0] } ?? [])
    }
}

// MARK: - Poster

/// One poster on the end card: focusable, growing and outlined on focus like
/// the panel's buttons, and opening its title on Select.
final class EndCardPosterView: UIControl {
    var onSelect: (() -> Void)?
    /// Focus gained or lost, and whether the person moved it there.
    var onFocus: ((_ focused: Bool, _ byUser: Bool) -> Void)?

    private let imageView = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(item: MediaItem) {
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)
        if let url = item.grandparentArtwork?.poster ?? item.artwork.poster {
            imageView.image = ImageCacheManager.shared.cachedImage(for: url)
            if imageView.image == nil {
                imageTask = Task { [weak self] in
                    let image = await ImageCacheManager.shared.image(for: url)
                    guard let self, !Task.isCancelled else { return }
                    self.imageView.image = image
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard focused || context.previouslyFocusedView === self else { return }
        coordinator.addCoordinatedAnimations({
            self.transform = focused ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
            self.layer.shadowOpacity = focused ? 0.5 : 0
            self.imageView.layer.borderWidth = focused ? 3 : 0
            self.imageView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        }, completion: nil)
        onFocus?(focused, focused && !context.focusHeading.isEmpty)
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on tvOS.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            onSelect?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // The release must not bubble: once the panel is gone the player reads it as Select on the video.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesEnded(presses, with: event)
    }
}

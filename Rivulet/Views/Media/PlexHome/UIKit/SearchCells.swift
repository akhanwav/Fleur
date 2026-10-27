// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchCells.swift
//  Rivulet
//
//  Full-width cells for the UIKit search surface (PlexHomeViewController
//  in `.search` mode):
//
//   - SearchRecentsCell: the empty-query state — a "Recently Searched" grid
//     of the items you last opened from search (#292), sized to fit the page,
//     with Clear All in its heading row and "No recent searches" when empty.
//   - SearchStateCell: inline searching / error / no-results states.
//     Port of PlexSearchView.loadingView / errorView / noResultsView.
//
//  Both cells are non-focusable containers (canFocusItemAt false in the
//  controller); their interactive content (recent cards, Try Again) are
//  FocusableActionButtons, which the engine focuses directly.
//
//  The section that hosts the recents cell is still called `.searchPrompt`
//  (24 references). It no longer renders a prompt: the centred magnifier and
//  "Search Your Libraries" went with the Apple TV layout. With no recents it
//  shows only the heading and "No recent searches".
//

import UIKit

// MARK: - Recently Searched

@MainActor
final class SearchRecentsCell: UICollectionViewCell {
    static let reuseID = "SearchRecentsCell"

    var onRecentSelected: ((MediaItem) -> Void)?
    /// "Clear All" in the heading row. The controller confirms first.
    var onClearAll: (() -> Void)?

    /// A grid of the Apple TV app's recent-search card, sized to the space it
    /// is given so every recent shows without scrolling. Its corner radius is
    /// our own.
    private enum Metrics {
        static let columns = 2
        /// Rows the grid is sized for, whatever the count: tiles keep one size
        /// as recents are added. Columns x rows is the most it shows.
        static let rows = 5
        static let columnGap: CGFloat = MediaRowMetrics.tileGap
        static let rowGap: CGFloat = 24
        static let maxCardHeight: CGFloat = 160
        static let minCardHeight: CGFloat = 96
        /// The card height before the controller passes one (and in tests).
        static let fallbackAvailableHeight: CGFloat = 774
        static let posterInsetRatio: CGFloat = 0.125
        static let posterToText: CGFloat = 24
        static let cardRadius: CGFloat = 20
        static let posterRadius: CGFloat = 6
        /// Gap below the keyboard's separator line.
        ///
        /// The search controller already sizes the results view to the area
        /// below its chrome, leaving ~43pt of its own, so this is the remainder
        /// needed to match the Apple TV app's ~57pt. It is the ONLY top spacing
        /// now: the page's `contentInset.top` is 0 in search mode, because 48
        /// there plus 48 here stacked into a 139pt gap.
        static let topPadding: CGFloat = 17
        static let headerToGrid: CGFloat = 16
        /// Clear of the screen's bottom edge.
        static let bottomPadding: CGFloat = 60
        static let clearButtonHeight: CGFloat = 44
    }

    static var maxItems: Int { Metrics.columns * Metrics.rows }

    /// True for a Recently Searched Clear All button, which lives in a cell's
    /// content view.
    static func isClearAllButton(_ view: UIView?) -> Bool {
        guard let view, let cell = view.superview?.superview as? SearchRecentsCell else { return false }
        return cell.clearButton === view
    }

    private let headerLabel = UILabel()
    private let clearButton = FocusableActionButton()
    /// Spans the heading row and leads to Clear All, so Up from either column
    /// reaches it (the button sits above the right one only). Off while the
    /// button has focus, or Left from it would land back on it instead of
    /// moving on to the keyboard.
    private let headerGuide = UIFocusGuide()
    private let emptyLabel = UILabel()
    private let grid = UIStackView()
    private var cards: [FocusableActionButton] = []
    /// The card focus last left from, so coming back (Up from Trending)
    /// lands where it was rather than on the first card.
    private weak var lastFocusedCard: FocusableActionButton?
    /// One per visible card, cancelled on reconfigure/reuse.
    private var artworkTasks: [Task<Void, Never>] = []
    private var recentItems: [MediaItem] = []
    private(set) var cardHeight: CGFloat = 0

    /// The focused card's item and window frame, for its long-press menu.
    var focusedRecent: (item: MediaItem, frame: CGRect)? {
        guard let index = cards.firstIndex(where: \.isFocused),
              let item = recentItems[safe: index] else { return nil }
        let card = cards[index]
        return (item, card.convert(card.bounds, to: nil))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        // Matches the shelf row headers (ShelfRowCell) so Search reads as the
        // same page as Home, not a separate design.
        headerLabel.text = "Recently Searched"
        headerLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        headerLabel.textColor = .secondaryLabel
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "No recent searches"
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let clearIcon = UIImageView(image: UIImage(systemName: "xmark")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        clearIcon.tintColor = .white
        let clearLabel = UILabel()
        clearLabel.text = "Clear All"
        clearLabel.font = .systemFont(ofSize: 24, weight: .medium)
        clearLabel.textColor = .white
        let clearContent = UIStackView(arrangedSubviews: [clearIcon, clearLabel])
        clearContent.spacing = 10
        clearContent.alignment = .center
        clearContent.isUserInteractionEnabled = false
        clearContent.translatesAutoresizingMaskIntoConstraints = false
        clearButton.addSubview(clearContent)
        clearButton.invertOnFocus = [clearIcon, clearLabel]
        clearButton.layer.cornerRadius = Metrics.clearButtonHeight / 2
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.onPrimaryAction = { [weak self] in self?.onClearAll?() }

        grid.axis = .vertical
        grid.spacing = Metrics.rowGap
        grid.alignment = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(headerLabel)
        contentView.addSubview(clearButton)
        contentView.addSubview(emptyLabel)
        contentView.addSubview(grid)
        contentView.addLayoutGuide(headerGuide)
        headerGuide.preferredFocusEnvironments = [clearButton]

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: Metrics.topPadding),
            headerLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: MediaRowMetrics.rowLeading),

            // The pill is taller than the heading's line: centred on it, so the
            // grid's top (and the height it is fitted to) stay the heading's.
            clearButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -MediaRowMetrics.rowLeading),
            clearButton.heightAnchor.constraint(equalToConstant: Metrics.clearButtonHeight),
            clearContent.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            clearContent.leadingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: 24),
            clearContent.trailingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: -24),

            headerGuide.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
            headerGuide.trailingAnchor.constraint(equalTo: clearButton.trailingAnchor),
            headerGuide.topAnchor.constraint(equalTo: clearButton.topAnchor),
            headerGuide.bottomAnchor.constraint(equalTo: clearButton.bottomAnchor),

            emptyLabel.topAnchor.constraint(
                equalTo: headerLabel.bottomAnchor, constant: Metrics.headerToGrid),
            emptyLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),

            grid.topAnchor.constraint(
                equalTo: headerLabel.bottomAnchor, constant: Metrics.headerToGrid),
            grid.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: MediaRowMetrics.rowLeading),
            grid.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -MediaRowMetrics.rowLeading),
            grid.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Metrics.bottomPadding)
        ])
    }

    /// The cell is the collection view's focus item, but it is a big empty area
    /// and should never hold focus itself — redirect straight into the cards.
    /// (A collection view enumerates focus items as CELLS, so a non-focusable
    /// cell would hide the cards from the engine entirely.)
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard !grid.isHidden else { return super.preferredFocusEnvironments }
        let remembered = lastFocusedCard.map { [$0 as UIFocusEnvironment] } ?? []
        return remembered + cards + [clearButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        headerGuide.isEnabled = context.nextFocusedView !== clearButton
        if let card = context.nextFocusedView as? FocusableActionButton, cards.contains(card) {
            lastFocusedCard = card
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtwork()
    }

    private func cancelArtwork() {
        artworkTasks.forEach { $0.cancel() }
        artworkTasks.removeAll()
    }

    /// The card height that fits `Metrics.rows` rows, the header and the
    /// padding into `availableHeight`, the page height below the keyboard.
    static func cardHeight(fitting availableHeight: CGFloat, headerHeight: CGFloat) -> CGFloat {
        let gridHeight = availableHeight - Metrics.topPadding - headerHeight
            - Metrics.headerToGrid - Metrics.bottomPadding
        let rows = CGFloat(Metrics.rows)
        let fitted = ((gridHeight - Metrics.rowGap * (rows - 1)) / rows).rounded(.down)
        return min(Metrics.maxCardHeight, max(Metrics.minCardHeight, fitted))
    }

    /// Returns true when the card height changed, so the caller can re-measure
    /// the cell.
    @discardableResult
    func configure(recentItems: [MediaItem], availableHeight: CGFloat? = nil) -> Bool {
        cancelArtwork()
        let items = Array(recentItems.prefix(Self.maxItems))
        self.recentItems = items
        cards = []
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasRecents = !items.isEmpty
        grid.isHidden = !hasRecents
        clearButton.isHidden = !hasRecents
        headerGuide.isEnabled = hasRecents && !clearButton.isFocused
        emptyLabel.isHidden = hasRecents

        let height = Self.cardHeight(
            fitting: availableHeight ?? Metrics.fallbackAvailableHeight,
            headerHeight: headerLabel.font.lineHeight.rounded(.up))
        let changed = height != cardHeight
        cardHeight = height
        guard hasRecents else { return changed }

        // Newest first, across then down.
        for start in stride(from: 0, to: items.count, by: Metrics.columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Metrics.columnGap
            row.distribution = .fillEqually
            for item in items[start..<min(start + Metrics.columns, items.count)] {
                let (card, poster) = Self.makeCard(for: item, height: height)
                card.onPrimaryAction = { [weak self] in self?.onRecentSelected?(item) }
                row.addArrangedSubview(card)
                cards.append(card)
                guard let url = item.artwork.poster else { continue }
                // @MainActor class, so the task inherits the main actor and the
                // assignment needs no hop. Cancelled on reuse via `artworkTasks`.
                artworkTasks.append(Task { [weak poster] in
                    let image = await ImageCacheManager.shared.image(for: url)
                    guard !Task.isCancelled else { return }
                    poster?.image = image
                })
            }
            // A short last row keeps its card at column width.
            while row.arrangedSubviews.count < Metrics.columns {
                row.addArrangedSubview(UIView())
            }
            grid.addArrangedSubview(row)
        }
        return changed
    }

    /// One Recently Searched card: the poster and the title, nothing else.
    ///
    /// `.glass` focus rather than the pill inversion the recents pills used:
    /// a card carries artwork, and a white fill with inverted text under a
    /// full-colour poster reads as a rendering bug.
    ///
    /// Returns the poster view so the caller can fill it asynchronously.
    private static func makeCard(for item: MediaItem, height: CGFloat) -> (FocusableActionButton, UIImageView) {
        let button = FocusableActionButton()
        button.focusStyle = .glass
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = Metrics.cardRadius

        let inset = (height * Metrics.posterInsetRatio).rounded()
        let posterHeight = height - inset * 2

        let poster = UIImageView()
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.layer.cornerRadius = Metrics.posterRadius
        poster.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        poster.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = item.title
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = .white
        title.numberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.isUserInteractionEnabled = false
        title.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(poster)
        button.addSubview(title)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: height),

            poster.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: inset),
            poster.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            poster.heightAnchor.constraint(equalToConstant: posterHeight),
            poster.widthAnchor.constraint(equalToConstant: (posterHeight * 2 / 3).rounded()),

            title.leadingAnchor.constraint(
                equalTo: poster.trailingAnchor, constant: Metrics.posterToText),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: button.trailingAnchor, constant: -inset),
            title.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        return (button, poster)
    }
}

// MARK: - Searching / error / no-results states

@MainActor
final class SearchStateCell: UICollectionViewCell {
    static let reuseID = "SearchStateCell"

    enum State {
        case searching
        case error(message: String)
        case noResults

        /// Only the error state renders Try Again, so only it is worth making
        /// the cell focusable for.
        var hasFocusableAction: Bool {
            if case .error = self { return true }
            return false
        }
    }

    var onRetry: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .large)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = FocusableActionButton()
    private let retryLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        spinner.color = .white

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 38, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 25, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 520

        retryLabel.text = "Try Again"
        retryLabel.font = .systemFont(ofSize: 26, weight: .medium)
        retryLabel.textColor = .white
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.layer.cornerRadius = 16
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addSubview(retryLabel)
        retryButton.invertOnFocus = [retryLabel]
        retryButton.onPrimaryAction = { [weak self] in self?.onRetry?() }
        NSLayoutConstraint.activate([
            retryLabel.leadingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: 32),
            retryLabel.trailingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: -32),
            retryLabel.topAnchor.constraint(equalTo: retryButton.topAnchor, constant: 18),
            retryLabel.bottomAnchor.constraint(equalTo: retryButton.bottomAnchor, constant: -18)
        ])

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 140),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40)
        ])
    }

    /// Same redirect as `SearchRecentsCell`: the cell is the focus item the
    /// collection view offers, Try Again is what should actually take focus.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        retryButton.isHidden ? super.preferredFocusEnvironments : [retryButton]
    }

    func configure(state: State) {
        switch state {
        case .searching:
            spinner.isHidden = false
            spinner.startAnimating()
            iconView.isHidden = true
            titleLabel.text = "Searching"
            messageLabel.isHidden = true
            retryButton.isHidden = true
        case .error:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "exclamationmark.triangle")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            // The Apple TV app's wording.
            titleLabel.text = "Search Not Available"
            messageLabel.isHidden = false
            messageLabel.text = "This request wasn’t completed. Wait a moment and try again."
            retryButton.isHidden = false
        case .noResults:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "sparkles")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            titleLabel.text = "No Results"
            messageLabel.isHidden = false
            messageLabel.text = "Try a different title or check your spelling."
            retryButton.isHidden = true
        }
    }
}

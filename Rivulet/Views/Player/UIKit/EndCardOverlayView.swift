//
//  EndCardOverlayView.swift
//  Rivulet
//
//  The end card: when a show's latest episode or a movie ends, "You're all
//  caught up on <show>" (or "More Like This") over the credits, a row of
//  related titles and, for a show, Back to Show. Selecting a title opens its
//  page; Back closes the card. It closes by itself after
//  `UniversalPlayerViewModel.endCardSeconds` unless the person moves on it.
//
//  The view spans the bottom of the screen over a dark gradient. While it is
//  up the player's content anchor is disabled, so it occludes nothing focusable.
//

import UIKit

final class EndCardOverlayView: UIView {

    private enum Metrics {
        static let headerToRow: CGFloat = 28
        static let bottom: CGFloat = 40
        static let scrimHeightFraction: CGFloat = 0.75
    }

    /// A related title was selected.
    var onSelect: ((MediaItem) -> Void)?
    /// Back to Show.
    var onBackToShow: (() -> Void)?
    /// A focus move the person made: the card stays up.
    var onUserFocusMove: (() -> Void)?

    private let scrim = CAGradientLayer()
    private let titleLabel = UILabel()
    private let backButton = PostVideoButtonView(isPrimary: true)
    private let collectionView: UICollectionView
    private var items: [MediaItem] = []
    private var show: MediaItem?

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        let tile = MediaRowMetrics.poster
        layout.itemSize = CGSize(width: tile.frame.width,
                                 height: tile.frame.height + MediaRowMetrics.posterCaptionHeight)
        layout.minimumLineSpacing = tile.gap
        layout.sectionInset = UIEdgeInsets(top: 0, left: tile.leading, bottom: 0, right: tile.leading)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        alpha = 0
        scrim.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                        UIColor.black.withAlphaComponent(0.85).cgColor]
        scrim.locations = [0, 0.45]
        layer.addSublayer(scrim)

        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        backButton.configure(title: "Back to Show", systemImage: "chevron.backward")
        backButton.onTap = { [weak self] in self?.onBackToShow?() }
        backButton.onUserFocus = { [weak self] in self?.onUserFocusMove?() }

        collectionView.backgroundColor = .clear
        // The section inset is the whole margin: tvOS's safe area would add another.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.clipsToBounds = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self

        let header = UIStackView(arrangedSubviews: [titleLabel, backButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 40

        [header, collectionView].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let rowHeight = MediaRowMetrics.poster.frame.height + MediaRowMetrics.posterCaptionHeight
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MediaRowMetrics.rowLeading),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: rowHeight),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottom),
            header.bottomAnchor.constraint(equalTo: collectionView.topAnchor, constant: -Metrics.headerToRow),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height * Metrics.scrimHeightFraction
        scrim.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        CATransaction.commit()
    }

    func configure(_ content: EndCardContent) {
        titleLabel.text = content.title
        show = content.show
        backButton.isHidden = content.show == nil
        items = content.related
        collectionView.isHidden = items.isEmpty
        collectionView.reloadData()
    }

    func fadeIn() {
        UIView.animate(withDuration: 0.4) { self.alpha = 1 }
    }

    func fadeOut(completion: @escaping () -> Void) {
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.3, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
            completion()
        })
    }

    // MARK: - Focus

    /// A show's card lands on Back to Show, so a stray Select does not open
    /// another title; a movie's has only the row.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        show != nil ? [backButton] : [collectionView]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if !context.focusHeading.isEmpty, context.nextFocusedView?.isDescendant(of: self) == true {
            onUserFocusMove?()
        }
    }
}

extension EndCardOverlayView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
        cell.configure(item: items[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(items[indexPath.item])
    }
}

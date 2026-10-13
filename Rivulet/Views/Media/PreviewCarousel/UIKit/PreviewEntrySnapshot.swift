// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewEntrySnapshot.swift
//  Rivulet
//
//  UIKit-only handoff for the row -> preview carousel entrance. The presenter
//  captures visible source tile snapshots before presentation; the carousel VC
//  owns animating those views into its card geometry.
//

import UIKit

@MainActor
struct PreviewEntrySnapshot {
    let itemIndex: Int
    let sourceFrame: CGRect
    let snapshotView: UIView
    /// The tile's own corner radius: where the flying card starts and lands.
    var cornerRadius: CGFloat = 16

    /// Snapshot of a tile's artwork (the whole cell when it declares none),
    /// framed in window space. `afterScreenUpdates` for a tile un-hidden just now.
    static func capture(
        _ cell: UICollectionViewCell, itemIndex: Int, in window: UIWindow, afterScreenUpdates: Bool
    ) -> PreviewEntrySnapshot? {
        let tile = cell as? PreviewSourceTile
        let art = tile?.previewArtworkView ?? cell
        let frame = art.convert(art.bounds, to: window)
        guard tile?.previewArtworkLoaded != false, frame.width > 1, frame.height > 1,
              let snapshot = cell.resizableSnapshotView(
                from: art.convert(art.bounds, to: cell),
                afterScreenUpdates: afterScreenUpdates, withCapInsets: .zero)
        else { return nil }
        return PreviewEntrySnapshot(
            itemIndex: itemIndex, sourceFrame: frame, snapshotView: snapshot,
            cornerRadius: tile?.previewCornerRadius ?? 16)
    }
}

/// A tile that flies into the preview carousel as its artwork alone.
@MainActor
protocol PreviewSourceTile: UICollectionViewCell {
    var previewArtworkView: UIView { get }
    var previewCornerRadius: CGFloat { get }
    /// False while the tile still shows a placeholder.
    var previewArtworkLoaded: Bool { get }
}

/// Clipping window for a captured tile snapshot during the row -> carousel
/// morph.
///
/// A `snapshotView(afterScreenUpdates:)` stretches its contents to whatever
/// bounds you assign, so animating one straight to the card frame squashes it
/// (a 2:3 poster tile into a ~1.62:1 card is x5.68 across but x2.34 down).
/// The window takes that frame instead; the snapshot inside is aspect-filled
/// and top-anchored, so it scales uniformly and overflows the bottom edge.
///
/// No display link needed: both endpoint content frames satisfy
/// `h = w / aspect`, and linear interpolation preserves that, so the ratio
/// holds at every intermediate frame.
@MainActor
final class EntryMorphWindowView: UIView {

    /// The card's artwork, shown under the tile snapshot for the whole flight.
    struct Backdrop {
        let imageView: UIImageView
        let cardSize: CGSize
        /// The artwork's frame inside the card at full size (the plane's rule).
        let artInCard: CGRect
    }

    private let contentAspect: CGFloat
    private let content: UIView
    private let backdrop: Backdrop?
    /// Black wash over the artwork, under the tile: the neighbour dim.
    private let dim = UIView()

    var tileAlpha: CGFloat {
        get { content.alpha }
        set { content.alpha = newValue }
    }
    var dimAlpha: CGFloat {
        get { dim.alpha }
        set { dim.alpha = newValue }
    }

    /// `sourceSize` is the size the snapshot was captured at — its true aspect.
    init(content: UIView, sourceSize: CGSize, backdrop: Backdrop? = nil) {
        self.content = content
        self.backdrop = backdrop
        self.contentAspect = sourceSize.height > 0
            ? sourceSize.width / sourceSize.height
            : 1
        super.init(frame: CGRect(origin: .zero, size: sourceSize))
        clipsToBounds = true
        layer.cornerCurve = .continuous
        if let backdrop {
            addSubview(backdrop.imageView)
            dim.backgroundColor = .black
            dim.alpha = 0
            addSubview(dim)
        }
        content.removeFromSuperview()
        addSubview(content)
        setWindow(CGRect(origin: .zero, size: sourceSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not Storyboard-backed") }

    /// Call inside an animation block — both frames tween on that curve.
    func setWindow(_ rect: CGRect) {
        frame = rect
        content.frame = Self.contentFrame(inWindowOfSize: rect.size, aspect: contentAspect)
        guard let backdrop else { return }
        backdrop.imageView.frame = Self.backdropFrame(
            inWindowOfSize: rect.size, cardSize: backdrop.cardSize, artInCard: backdrop.artInCard)
        dim.frame = CGRect(origin: .zero, size: rect.size)
    }

    /// The card's artwork in a window of `size`: the card aspect-filled by the
    /// content rule, its artwork scaled with it. At the card's own size this is
    /// `artInCard`, so the flight ends where the backdrop plane draws it.
    static func backdropFrame(inWindowOfSize size: CGSize, cardSize: CGSize, artInCard: CGRect) -> CGRect {
        guard cardSize.width > 0, cardSize.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let box = contentFrame(inWindowOfSize: size, aspect: cardSize.width / cardSize.height)
        let scale = box.width / cardSize.width
        return CGRect(
            x: box.minX + artInCard.minX * scale,
            y: box.minY + artInCard.minY * scale,
            width: artInCard.width * scale,
            height: artInCard.height * scale
        )
    }

    /// Aspect-fill, anchored to the window's top edge so growth spills off the
    /// bottom.
    static func contentFrame(inWindowOfSize size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let width = size.width >= size.height * aspect
            ? size.width
            : size.height * aspect
        let height = width / aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: 0,
            width: width,
            height: height
        )
    }
}

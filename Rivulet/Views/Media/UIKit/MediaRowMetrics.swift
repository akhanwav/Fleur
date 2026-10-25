// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaRowMetrics.swift
//  Rivulet
//
//  THE single source of tile + row metrics for every media shelf row:
//  home/library hub rows, the watchlist row, loading skeletons, and the
//  detail page's Related row. Layout sections AND cell-internal constraints
//  must read from here — the sizes drifting apart across copies is exactly
//  the bug class this file exists to kill.
//
//  Margin, gap and tile widths are the Apple TV app's grid (tvOS 26.5).
//

import UIKit

enum MediaRowMetrics {
    // MARK: The grid
    //
    // 80 pt side margin, 40 pt between tiles, and a tile width that divides
    // what is left by the column count: 6 across = 260 (posters), 5 = 320
    // (Continue Watching), 3 = 560. At rest N tiles show in full and tile
    // N + 1 shows a 40 pt sliver on the right; one step on, tile k + 1 sits
    // where tile k was and the tile before it shows the same sliver on the left:
    //
    //     1920 = 2·rowLeading + N·width + (N − 1)·tileGap
    //
    // These are ARTWORK numbers. A cell is its lockup's FRAME, which is larger
    // (see "Lockup frames"), so each shelf lays frames out `pitch` apart and
    // pulls its inset and spacing in by that reserve. ShelfRowCell drives its
    // own offset to pitch multiples, so the landings are exact.

    /// The app-wide content margin: hero, shelf headers, tile artwork, the
    /// expanded detail (`PreviewCarouselGeometry.expandedChromeInset`), popups.
    static let rowLeading: CGFloat = 80
    static let rowTrailing: CGFloat = rowLeading

    /// Gap between the artwork of neighbouring tiles.
    static let tileGap: CGFloat = 40

    /// Width of a tile covering `span` of `columns` grid columns.
    static func gridWidth(columns: Int, span: Int = 1) -> CGFloat {
        let column = (1920 - 2 * rowLeading - CGFloat(columns - 1) * tileGap) / CGFloat(columns)
        return (column * CGFloat(span) + tileGap * CGFloat(span - 1)).rounded(.down)
    }

    /// Fully-visible tile count per shelf type (the N in the equation).
    static let posterFullCount = 6
    static let cwFullCount = 5
    static let liveFullCount = 4

    // MARK: Lockup frames
    //
    // TVPosterView and TVCardView rest their artwork short of their frame and
    // grow it to fill the frame on focus. A poster grows `focusGrowth` on its
    // long side and the other side in proportion; a card grows it on both.
    static let focusGrowth: CGFloat = 40

    /// A tile: its resting artwork, and the lockup frame (the cell) around it.
    struct Tile {
        enum Lockup { case poster, card }
        let art: CGSize
        var lockup = Lockup.poster

        /// Whole points: compositional layout floors a fractional item width,
        /// which would shorten the pitch.
        var frame: CGSize {
            let growth = MediaRowMetrics.focusGrowth
            switch lockup {
            case .card:
                return CGSize(width: art.width + growth, height: art.height + growth)
            case .poster:
                let scale = 1 + growth / max(art.width, art.height)
                return CGSize(width: (art.width * scale).rounded(), height: (art.height * scale).rounded())
            }
        }
        /// Spacing between frames that leaves `tileGap` between the artwork.
        var gap: CGFloat { MediaRowMetrics.tileGap - (frame.width - art.width) }
        /// Frame inset that rests the first tile's artwork on `rowLeading`.
        var leading: CGFloat { MediaRowMetrics.rowLeading - (frame.width - art.width) / 2 }
    }

    // MARK: Tiles

    /// 2:3 poster (PosterCell, WatchlistPosterCell, detail Related row).
    static let poster: Tile = {
        let width = gridWidth(columns: posterFullCount)
        return Tile(art: CGSize(width: width, height: width * 1.5))
    }()
    static let posterWidth = poster.frame.width
    static let posterHeight = poster.frame.height

    /// 1:1 square for music (artist/album/track): the poster's grid column.
    static let music = Tile(art: CGSize(width: poster.art.width, height: poster.art.width))
    static let musicWidth = music.frame.width
    static let musicHeight = music.frame.height

    /// Continue Watching card: a 16:9 still over a 48pt band (Apple's Up Next).
    static let continueWatching: Tile = {
        let width = gridWidth(columns: cwFullCount)
        return Tile(art: CGSize(width: width, height: (width * 9 / 16 + 48).rounded()), lockup: .card)
    }()
    static let cwWidth = continueWatching.frame.width
    static let cwHeight = continueWatching.frame.height

    /// Live TV Browse card (16:9), on the Apple TV app's live-row geometry:
    /// four across, its ~88pt margin and 40pt gap, so both peeks stay wide.
    /// 2·88 + 4·406 + 3·40 = 1920 → 48pt sliver. The Browse page only, with
    /// numbers of its own (frames, not artwork).
    static let liveLeading: CGFloat = 88
    static let liveWidth: CGFloat = 406
    static let liveHeight: CGFloat = 228
    static let liveGap: CGFloat = 40

    // MARK: Row chrome (vertical)

    /// Extra group height beneath tiles for the focus-scale growth.
    /// (Was 80 when tiles were smaller and carried a drop shadow.)
    static let focusGrowthPadding: CGFloat = 48

    /// Settings → Appearance → Show Titles Under Posters (on by default).
    static var showsPosterTitles: Bool { SettingsStore.bool("showPosterTitles", default: true) }
    /// Room a poster row or grid adds under each tile for its title and year;
    /// 0 with the setting off.
    static var posterCaptionHeight: CGFloat { showsPosterTitles ? PosterCaptionView.height : 0 }

    /// Vertical insets around each row section. (Were 12 / 15.)
    static let rowTopInset: CGFloat = 8
    static let rowBottomInset: CGFloat = 8
}

extension NSLayoutConstraint {
    /// Returns self with a non-required priority. Used on cell-internal
    /// constraints that meet TVUIKit's transient zero-width first layout pass
    /// (TVCardView lays its content host out at width 0 before contentSize
    /// applies) — at 999 Auto Layout compromises silently instead of spamming
    /// "Unable to simultaneously satisfy constraints" on every cell configure.
    func withPriority(_ rawValue: Float) -> NSLayoutConstraint {
        priority = UILayoutPriority(rawValue)
        return self
    }
}

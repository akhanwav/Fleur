// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AppTheme.swift
//  Rivulet
//
//  The browsing pages' colours in one place: Home, Search, Watchlist,
//  Discover, the library pages and the shell behind them. A dynamic colour,
//  so a light appearance can be given its own value here and every page
//  follows. Detail pages and the player keep their own.
//
//  And the pages' fonts: SF Pro for titles, Libre Franklin for descriptions and
//  details lines. Everything else stays in the system font: info boxes and the
//  tags on cards and posters (Libre Franklin's metrics sit them off centre),
//  pop-ups, pickers, menus, settings and poster captions.
//

import UIKit

enum AppTheme {
    nonisolated enum Fonts {
        /// A movie's, show's or episode's own title.
        static func title(_ size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
            .systemFont(ofSize: size, weight: weight)
        }

        /// Descriptions, synopses, bios and the values in a page's Information,
        /// Languages and Accessibility sections. Regular, never lighter: read
        /// from across a room.
        static func description(_ size: CGFloat) -> UIFont { supporting(size, weight: 400) }
        /// The "S1, E3:" in front of an episode's description.
        static func descriptionLead(_ size: CGFloat) -> UIFont { supporting(size, weight: 700) }
        static func tagline(_ size: CGFloat) -> UIFont { supporting(size, weight: 400, italic: true) }
        /// Details lines: year, season, "3 Seasons", rating, runtime.
        static func details(_ size: CGFloat) -> UIFont { supporting(size, weight: 500) }

        /// Libre Franklin (Rivulet/Resources/Fonts, listed under `UIAppFonts`)
        /// is one variable font per style, so a weight is an axis value. Named
        /// by family: the file's default instance is Thin.
        private static func supporting(_ size: CGFloat, weight: Int, italic: Bool = false) -> UIFont {
            let wghtAxis = 0x7767_6874  // 'wght'
            var attributes: [UIFontDescriptor.AttributeName: Any] = [
                .family: "Libre Franklin",
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
            ]
            if italic { attributes[.traits] = [UIFontDescriptor.TraitKey.symbolic: UIFontDescriptor.SymbolicTraits.traitItalic.rawValue] }
            return UIFont(descriptor: UIFontDescriptor(fontAttributes: attributes), size: size)
        }
    }

    /// The solid page background. Black in both appearances for now.
    static let pageBackground = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .light: return .black
        default: return .black
        }
    }
}

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

import UIKit

enum AppTheme {
    /// The solid page background. Black in both appearances for now.
    static let pageBackground = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .light: return .black
        default: return .black
        }
    }
}

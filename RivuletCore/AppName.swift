// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AppName.swift
//  Rivulet
//
//  The name a user sees, in one place: the app's display name under its icon
//  (`CFBundleDisplayName` in the app's Info.plist), read back here so every
//  sentence, alert and user agent says the same. To rename the app, change
//  that one Info.plist value. Internal names (types, modules, bundle IDs,
//  logging subsystems) keep "Rivulet".
//

import Foundation

nonisolated enum AppName {
    /// "PLOX" on Apple TV.
    static let display: String = {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "Rivulet"
    }()
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexHomeRoot.swift
//  Rivulet
//
//  SwiftUI shell for the Plex Home screen. Wraps the UIKit
//  `PlexHomeViewController` (via `PlexHomeUIKitBridge`).
//

import SwiftUI

struct PlexHomeRoot: View {
    var body: some View {
        UIKitHomeContainer()
    }
}

/// SwiftUI shell for the UIKit home. All navigation happens inside UIKit.
/// The `NavigationStack` wrapper stays only because removing it would change
/// the home's hosting identity.
struct UIKitHomeContainer: View {
    /// Surface to render — .home (default) or .library(key:title:). Library
    /// call sites pass their key/title and `.id(key)` the container so each
    /// library gets a fresh controller.
    var mode: HomeMode = .home

    var body: some View {
        NavigationStack {
            PlexHomeUIKitBridge(mode: mode)
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VideoZoomAdjustment.swift
//  Rivulet
//
//  Fit vs. fill for the video surface: one global, persisted choice, applied
//  immediately on every press -- unlike Audio Sync this is a plain
//  display-layer property (AVLayerVideoGravity), not a pipeline reload, so
//  there's no debounce to worry about.
//

import AVFoundation

enum VideoZoomMode: String, CaseIterable {
    case fit
    case fill

    var title: String { self == .fit ? "Fit" : "Fill" }

    /// `AVLayerVideoGravity` is a plain AVFoundation type, not an AetherEngine
    /// one, so naming it here doesn't widen AetherPlayer's own import rule.
    var gravity: AVLayerVideoGravity { self == .fit ? .resizeAspect : .resizeAspectFill }
}

enum VideoZoomAdjustment {
    private static let defaultsKey = "videoZoomMode"

    static var mode: VideoZoomMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return .fit }
            return VideoZoomMode(rawValue: raw) ?? .fit
        }
        set {
            if newValue == .fit {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }

    /// `mode` stepped by `steps` and wrapped — does not persist or apply it;
    /// the caller (`UniversalPlayerViewModel.adjustVideoZoom`) does both.
    static func advanced(bySteps steps: Int) -> VideoZoomMode {
        let all = VideoZoomMode.allCases
        let current = all.firstIndex(of: mode) ?? 0
        let next = ((current + steps) % all.count + all.count) % all.count
        return all[next]
    }
}

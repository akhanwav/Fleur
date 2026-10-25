// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VideoTrack.swift
//  Rivulet
//
//  Per-video-stream metadata for the source picker and player UI.
//

import Foundation

struct VideoTrack: Hashable, Sendable, Identifiable {
    let id: String                 // provider-native stream id
    let codec: String              // "hevc", "h264", "av1", "vp9"
    let profile: String?           // "Main 10", "High", etc.
    let level: Int?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrate: Int?              // bits per second, like MediaSource.bitrate
    let videoRange: VideoRange
    let isDefault: Bool
    let scanType: String?           // Plex "progressive" / "interlaced"; nil if unknown

    var isInterlaced: Bool { scanType?.lowercased() == "interlaced" }

    enum VideoRange: Hashable, Sendable {
        case sdr
        case hdr10
        case hdr10Plus
        case hlg
        case dolbyVision(profile: Int)   // P5=5, P7=7, P8=8
    }
}

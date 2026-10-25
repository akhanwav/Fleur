// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HLSVariantDisplayInfo.swift
//  Rivulet
//
//  What a server transcode says it is sending, read from its master playlist.
//
//  The `hls` route plays a Plex transcode on a bare AVPlayer in an
//  AVPlayerLayer, and nothing there programs the display mode: only
//  AVPlayerViewController applies an item's criteria by itself. The master
//  playlist is the server's own account of the output, measured on PMS:
//  `FRAME-RATE=23.976000,VIDEO-RANGE=PQ` on the variant, and no CODECS, so it
//  gives the rate and the range but cannot tell Dolby Vision from HDR10.
//

import Foundation

nonisolated struct HLSVariantDisplayInfo: Equatable, Sendable {
    enum Range: Equatable, Sendable {
        case sdr
        case pq
        case hlg
    }

    let frameRate: Double?
    let range: Range
    let width: Int?
    let height: Int?

    /// The first `#EXT-X-STREAM-INF` of `master`, or nil when there is none
    /// (a media playlist, or not a playlist at all). A variant that states no
    /// VIDEO-RANGE is SDR, as the HLS spec defines it.
    static func parse(master: String) -> HLSVariantDisplayInfo? {
        guard let line = master.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else { return nil }
        let attributes = Self.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))

        let range: Range = switch attributes["VIDEO-RANGE"]?.uppercased() {
        case "PQ": .pq
        case "HLG": .hlg
        default: .sdr
        }
        let frameRate = attributes["FRAME-RATE"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        let size = attributes["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
        return HLSVariantDisplayInfo(
            frameRate: frameRate,
            range: range,
            width: size?.count == 2 ? size?[0] : nil,
            height: size?.count == 2 ? size?[1] : nil
        )
    }

    /// `KEY=VALUE` pairs, commas inside quoted values kept.
    private static func attributes(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var quoted = false
        func flush() {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result[trimmed.uppercased()] = value }
            key = ""; value = ""; readingValue = false
        }
        for character in list {
            switch character {
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                flush()
            case "=" where !readingValue:
                readingValue = true
            default:
                if readingValue { value.append(character) } else { key.append(character) }
            }
        }
        flush()
        return result
    }
}

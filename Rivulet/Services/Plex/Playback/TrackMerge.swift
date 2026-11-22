// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TrackMerge.swift
//  Rivulet
//
//  ONE track list, not two.
//
//  The player straddles two descriptions of the same streams:
//
//  - AETHERENGINE knows WHICH stream. It demuxes the container, so its stream
//    index is the only value `selectAudioTrack` / `selectSubtitleTrack` accept.
//  - PLEX knows WHAT the stream is: the human display title, the long-form
//    `extendedDisplayTitle` ("English (AC3 5.1) - Director's Commentary"), and
//    its own scanner's flags. But its stream ids mean nothing to the engine.
//
//  Keeping these as two parallel arrays and re-deriving the correspondence at
//  each call site is what produced issue #201: a language+codec `first(where:)`
//  match collapsed three same-language subtitles onto one engine index, so only
//  the first was ever selectable.
//
//  So merge once, here, at load. Each merged track carries the ENGINE's id —
//  making it directly selectable — plus Plex's labels. Downstream there is a
//  single id space and no translation step, so the bug class is unrepresentable
//  rather than merely fixed.
//
//  THE JOIN KEY IS THE CONTAINER STREAM INDEX, NOT ORDINAL POSITION.
//
//  Both sides already carry it: AetherEngine's `TrackInfo.id` IS the container
//  stream index (its Demuxer walks every stream in `nb_streams` and passes the
//  loop counter straight through as the id), and Plex reports the same value as
//  `PlexStream.index`. Joining on it is container truth.
//
//  Position would NOT be safe, and the difference is not theoretical: Plex emits
//  EIA-608/708 closed captions that are baked into the video stream as their own
//  entries in `Part.Stream` (flagged `embeddedInVideo`, and the reason
//  `PlexStream._id` is optional). FFmpeg surfaces no separate AVStream for those,
//  so the engine never reports them. Counting ordinals would shift every real
//  subtitle by one and silently mislabel the whole list — reintroducing #201's
//  exact symptom by a different mechanism. Joining on stream index simply never
//  matches the phantom, and everything else lines up.
//
//  External sidecar subtitles are the one exception: they are not in the
//  container, so they have no stream index. They are registered with the engine
//  in metadata order (`aetherExternalSubtitles()`), so they pair by that order
//  among themselves.
//

import Foundation

enum TrackMerge {

    /// Merge the engine's audio tracks with Plex's audio streams.
    static func mergeAudio(engine: [MediaTrack], plex: [MediaTrack]) -> [MediaTrack] {
        let byIndex = indexPlexStreams(plex)
        return engine.map { track in
            enrich(track, with: track.streamIndex.flatMap { byIndex[$0] })
        }
    }

    /// Merge the engine's subtitle tracks with Plex's subtitle streams.
    ///
    /// Embedded tracks join on container stream index. External sidecars have no
    /// stream index, so they pair with Plex's sidecar streams by registration
    /// order — the order `aetherExternalSubtitles()` handed them to the engine.
    static func mergeSubtitles(engine: [MediaTrack], plex: [MediaTrack]) -> [MediaTrack] {
        let byIndex = indexPlexStreams(plex.filter { $0.subtitleKey == nil })
        let externalPlex = plex.filter { $0.subtitleKey != nil }
        var externalOrdinal = 0

        return engine.map { track in
            if track.isExternal {
                let counterpart = externalOrdinal < externalPlex.count ? externalPlex[externalOrdinal] : nil
                externalOrdinal += 1
                return enrich(track, with: counterpart)
            }
            return enrich(track, with: track.streamIndex.flatMap { byIndex[$0] })
        }
    }

    /// Plex streams keyed by container stream index.
    ///
    /// A stream with no `index` cannot be joined and is dropped from the map —
    /// it would otherwise be a phantom counterpart. Duplicate indices keep the
    /// first (Plex should never emit them; be deterministic if it does).
    private static func indexPlexStreams(_ plex: [MediaTrack]) -> [Int: MediaTrack] {
        var map: [Int: MediaTrack] = [:]
        for track in plex {
            guard let index = track.streamIndex else { continue }
            if map[index] == nil { map[index] = track }
        }
        return map
    }

    // MARK: - Enrichment

    /// Fold a Plex stream's descriptive metadata onto an engine track.
    ///
    /// The engine track's `id` ALWAYS survives — it is the selection key, and
    /// the whole point of the merge.
    ///
    /// - `name`: prefer Plex's display title. It is human-authored; the engine
    ///   falls back to a raw container title that is often empty or just a codec.
    /// - `extendedDisplayTitle`: Plex-only. Feeds commentary detection and the
    ///   picker's long labels.
    /// - `isForced` / `isHearingImpaired` / `isDefault`: OR'd. Both sides read
    ///   the container's disposition bits, and Plex adds its own scan; either
    ///   asserting it is enough. (The engine DOES report all three — they were
    ///   simply being dropped in `AetherPlayer.translateTrack` before this
    ///   change, which is why the app used to believe only Plex knew.)
    /// - `isCommentary`: engine-only flag; no Plex equivalent.
    /// - `codec` / `channels`: prefer the engine. It is decoding the stream, so
    ///   it is authoritative on the stream's real shape; Plex's values come from
    ///   a scan that can be stale if a file was replaced in place.
    /// - `subtitleKey`: Plex-only (the sidecar URL path).
    private static func enrich(_ engineTrack: MediaTrack, with plexTrack: MediaTrack?) -> MediaTrack {
        guard let plexTrack else { return engineTrack }

        var merged = MediaTrack(
            id: engineTrack.id,                       // engine index — the selection key
            name: preferredName(engine: engineTrack, plex: plexTrack),
            language: plexTrack.language ?? engineTrack.language,
            languageCode: plexTrack.languageCode ?? engineTrack.languageCode,
            codec: engineTrack.codec ?? plexTrack.codec,
            isDefault: engineTrack.isDefault || plexTrack.isDefault,
            isForced: engineTrack.isForced || plexTrack.isForced,
            isHearingImpaired: engineTrack.isHearingImpaired || plexTrack.isHearingImpaired,
            isCommentary: engineTrack.isCommentary,   // engine-only flag
            extendedDisplayTitle: plexTrack.extendedDisplayTitle,
            channels: engineTrack.channels ?? plexTrack.channels,
            subtitleKey: plexTrack.subtitleKey,
            streamIndex: engineTrack.streamIndex,
            isExternal: engineTrack.isExternal
        )
        merged.origin = plexTrack.origin
        merged.releaseName = plexTrack.releaseName
        return merged
    }

    /// Plex's display title, unless it has nothing usable, in which case keep
    /// whatever the engine synthesized (localized language name, or codec).
    private static func preferredName(engine: MediaTrack, plex: MediaTrack) -> String {
        let plexName = plex.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return plexName.isEmpty ? engine.name : plexName
    }
}

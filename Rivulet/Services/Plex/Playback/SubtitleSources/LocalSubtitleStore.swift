//
//  LocalSubtitleStore.swift
//  Rivulet
//
//  Subtitles downloaded from OpenSubtitles or SubSource, kept on the Apple TV
//  per title per server, and offered as that title's own tracks: each one is
//  listed as a Plex sidecar stream whose key is the file's URL, so the player's
//  track list, the sidecar registration and the saved choices all treat it like
//  any other external subtitle. Only the aether route can show them: on the
//  `hls` route subtitles come from the server.
//

import Foundation

nonisolated struct LocalSubtitle: Codable, Sendable, Hashable {
    let streamID: Int
    /// `LocalSubtitleStore.serverKey`: "plex:<machineId>".
    let server: String
    let ratingKey: String
    let origin: SubtitleOrigin
    let release: String
    /// ISO 639-1.
    let language: String
    let isHearingImpaired: Bool
    let isForced: Bool
    /// "srt", "ass" or "vtt".
    let format: String
    let fileName: String
    let addedAt: Date
}

@MainActor
enum LocalSubtitleStore {
    /// Stream ids no Plex server hands out.
    static let streamIDBase = 1_900_000_000

    static func isLocal(streamID: Int) -> Bool { streamID >= streamIDBase }

    /// A server by its provider id ("plex:<machineId>"), which survives the
    /// address changing; the address itself for a server not registered.
    static func serverKey(serverURL: String) -> String {
        MediaProviderRegistry.shared.plexProvider(serverURL: serverURL)?.id ?? "url:\(serverURL)"
    }

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Subtitles", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    private static var cached: [LocalSubtitle]?

    static func all() -> [LocalSubtitle] {
        if let cached { return cached }
        let decoded = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([LocalSubtitle].self, from: $0) }
        // An entry whose file is gone (purged, never written) is not offered.
        let present = (decoded ?? []).filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
        cached = present
        return present
    }

    static func subtitles(server: String, ratingKey: String) -> [LocalSubtitle] {
        all().filter { $0.server == server && $0.ratingKey == ratingKey }
    }

    static func fileURL(_ subtitle: LocalSubtitle) -> URL { directory.appendingPathComponent(subtitle.fileName) }

    /// Stores `text` for the title. The same release from the same source
    /// replaces its earlier copy and keeps its id, so a saved choice still finds it.
    static func save(text: String, format: String, server: String, ratingKey: String, origin: SubtitleOrigin,
                     release: String, language: String, isHearingImpaired: Bool, isForced: Bool) throws -> LocalSubtitle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries = all()
        let existing = entries.firstIndex {
            $0.server == server && $0.ratingKey == ratingKey && $0.origin == origin && $0.release == release
                && $0.isHearingImpaired == isHearingImpaired
        }
        let streamID = existing.map { entries[$0].streamID } ?? ((entries.map(\.streamID).max() ?? streamIDBase) + 1)
        let fileName = "\(streamID).\(format)"
        let subtitle = LocalSubtitle(streamID: streamID, server: server, ratingKey: ratingKey, origin: origin,
                                     release: release, language: language, isHearingImpaired: isHearingImpaired,
                                     isForced: isForced, format: format, fileName: fileName, addedAt: Date())
        var url = fileURL(subtitle)
        try Data(text.utf8).write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        if let existing { entries[existing] = subtitle } else { entries.append(subtitle) }
        try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        cached = entries
        return subtitle
    }

    // MARK: - As Plex streams

    /// `media` with the title's stored subtitles appended to each version's
    /// first part, after Plex's own: the order the sidecars register in and
    /// `TrackMerge` pairs on. Earlier injections are dropped first, so it can
    /// run on every metadata change.
    static func injecting(into media: [PlexMedia], server: String, ratingKey: String?) -> [PlexMedia] {
        let stored = ratingKey.map { subtitles(server: server, ratingKey: $0) } ?? []
        let hasInjected = media.contains { $0.Part?.first?.Stream?.contains { isLocal(streamID: $0.id) } ?? false }
        guard !stored.isEmpty || hasInjected else { return media }
        return media.map { version in
            guard var parts = version.Part, let first = parts.first else { return version }
            let plexStreams = (first.Stream ?? []).filter { !isLocal(streamID: $0.id) }
            parts[0] = PlexPart(id: first.id, key: first.key, duration: first.duration, file: first.file,
                                size: first.size, container: first.container,
                                Stream: plexStreams + stored.map(stream(for:)))
            return PlexMedia(id: version.id, duration: version.duration, bitrate: version.bitrate,
                             width: version.width, height: version.height, aspectRatio: version.aspectRatio,
                             audioChannels: version.audioChannels, audioCodec: version.audioCodec,
                             videoCodec: version.videoCodec, videoResolution: version.videoResolution,
                             container: version.container, videoFrameRate: version.videoFrameRate, Part: parts)
        }
    }

    /// Whether two item listings carry the same streams, by id, version by version.
    static func sameStreams(_ a: [PlexMedia], _ b: [PlexMedia]) -> Bool {
        a.map { $0.Part?.first?.Stream?.map(\.id) ?? [] } == b.map { $0.Part?.first?.Stream?.map(\.id) ?? [] }
    }

    static func stream(for subtitle: LocalSubtitle) -> PlexStream {
        let languageName = TrackLabels.languageName(subtitle.language) ?? subtitle.language
        let code = Locale.LanguageCode(subtitle.language).identifier(.alpha3) ?? subtitle.language
        var stream = PlexStream(
            _id: subtitle.streamID, streamType: 3, index: nil, codec: subtitle.format, codecID: nil,
            language: languageName, languageCode: code, languageTag: subtitle.language,
            displayTitle: languageName, title: subtitle.release,
            default: false, forced: subtitle.isForced, selected: false,
            bitDepth: nil, chromaLocation: nil, chromaSubsampling: nil, colorPrimaries: nil, colorRange: nil,
            colorSpace: nil, colorTrc: nil, DOVIBLCompatID: nil, DOVIBLPresent: nil, DOVIELPresent: nil,
            DOVILevel: nil, DOVIPresent: nil, DOVIProfile: nil, DOVIRPUPresent: nil, DOVIVersion: nil,
            frameRate: nil, height: nil, width: nil, level: nil, profile: nil, refFrames: nil, scanType: nil,
            audioChannelLayout: nil, channels: nil, bitrate: nil, samplingRate: nil,
            format: subtitle.format, key: fileURL(subtitle).absoluteString,
            extendedDisplayTitle: "\(subtitle.release) (\(languageName) \(subtitle.format.uppercased()) \(subtitle.origin.label))",
            hearingImpaired: subtitle.isHearingImpaired)
        stream.providerTitle = subtitle.origin.label
        return stream
    }

    /// The detail page's form of a stored subtitle.
    static func subtitleTrack(_ subtitle: LocalSubtitle) -> SubtitleTrack? {
        PlexMediaMapper.subtitleTrack(stream(for: subtitle))
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TitleTrackChoices.swift
//  Rivulet
//
//  Per-title audio and subtitle choices from the detail page's Audio and
//  Subtitles pickers, and the default subtitles for a title with none.
//
//  A choice is kept here as well as sent to Plex (the per-part stream
//  selection, so other clients follow it), because Plex's `selected` flag
//  cannot say Off and cannot be told apart from Plex's own auto-selection.
//  It is stored by Plex guid, the same on every server, and as a track's
//  shape (language, format, flags) rather than its stream id, which differs
//  per copy and per episode: a choice made on one copy plays on any other,
//  and a choice made on a show's page covers every episode of the show.
//

import Foundation

/// What was picked for one title.
struct TitleTrackChoice: Codable, Equatable {
    var audio: AudioIntent?
    var subtitle: SubtitleIntent?
}

enum TitleTrackChoices {
    private static let defaultsKey = "titleTrackChoices"

    /// A movie's or episode's own guid, or a show's for every episode of it.
    static func key(guid: String?) -> String? {
        guard let guid, !guid.isEmpty else { return nil }
        return guid
    }

    static func choice(for key: String?) -> TitleTrackChoice? {
        guard let key else { return nil }
        return all()[key]
    }

    /// The choice that applies to a playing item: its own, else its show's.
    static func choice(guid: String?, showGuid: String?) -> TitleTrackChoice? {
        choice(for: key(guid: guid)) ?? choice(for: key(guid: showGuid))
    }

    static func setAudio(_ intent: AudioIntent, for key: String) {
        update(key) { $0.audio = intent }
    }

    static func setSubtitle(_ intent: SubtitleIntent, for key: String) {
        update(key) { $0.subtitle = intent }
    }

    private static func update(_ key: String, _ change: (inout TitleTrackChoice) -> Void) {
        var choices = all()
        var choice = choices[key] ?? TitleTrackChoice()
        change(&choice)
        choices[key] = choice
        if let data = try? JSONEncoder().encode(choices) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func all() -> [String: TitleTrackChoice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: TitleTrackChoice].self, from: data)) ?? [:]
    }
}

// MARK: - Default subtitles

/// Settings → Playback → Default Subtitles: what a title with no saved
/// choice starts with.
enum DefaultSubtitles: String, CaseIterable {
    /// English text subtitles, else English image ones (`EnglishSubtitleDefault`).
    case english
    /// The last subtitles picked in the player, on any title (`TrackIntentStore`).
    case lastUsed
    case off

    static let settingKey = "defaultSubtitles"

    static var current: DefaultSubtitles {
        UserDefaults.standard.string(forKey: settingKey).flatMap(DefaultSubtitles.init) ?? .english
    }

    var description: String {
        switch self {
        case .english: return "English"
        case .lastUsed: return "Last Used"
        case .off: return "Off"
        }
    }
}

/// The English default: SRT first, then another text format, then PGS, then
/// any other English track; full subtitles over forced-only ones, and plain
/// over SDH within a format. nil when the title has no English subtitles.
enum EnglishSubtitleDefault {
    static func pick<Track>(_ tracks: [Track], language: (Track) -> String?, codec: (Track) -> String?,
                            forced: (Track) -> Bool, sdh: (Track) -> Bool) -> Track? {
        let english = tracks.enumerated().filter { TrackLanguage.matches(language($0.element), TrackLanguage.english) }
        func formatRank(_ track: Track) -> Int {
            switch MediaTrack.normalizedSubtitleCodec(codec(track)) {
            case "srt": return 0
            case "ass", "webvtt", "mov_text", "ttml", "smi", "text": return 1
            case "pgs": return 2
            default: return 3
            }
        }
        return english.min { a, b in
            let ka = (forced(a.element) ? 1 : 0, formatRank(a.element), sdh(a.element) ? 1 : 0, a.offset)
            let kb = (forced(b.element) ? 1 : 0, formatRank(b.element), sdh(b.element) ? 1 : 0, b.offset)
            return ka < kb
        }?.element
    }

    static func pick(_ tracks: [MediaTrack]) -> MediaTrack? {
        pick(tracks, language: { $0.languageCode ?? $0.language }, codec: \.codec,
             forced: \.isForced, sdh: \.isHearingImpaired)
    }

    static func pick(_ tracks: [SubtitleTrack]) -> SubtitleTrack? {
        pick(tracks, language: \.language, codec: { $0.codec }, forced: \.isForced, sdh: \.isHearingImpaired)
    }
}

// MARK: - Matching a choice to a detail page's tracks

/// A saved choice against a copy's tracks, most exact first, as the player's
/// `TrackIntentResolver` matches it.
enum TitleTrackMatch {
    static func audio(_ intent: AudioIntent, in tracks: [AudioTrack]) -> AudioTrack? {
        let language = tracks.filter { TrackLanguage.matches($0.language, intent.language) }
        return language.first { TrackCodec.normalize($0.codec) == TrackCodec.normalize(intent.codec) && $0.channels == intent.channels }
            ?? language.first { TrackCodec.normalize($0.codec) == TrackCodec.normalize(intent.codec) }
            ?? language.first
    }

    static func subtitle(_ intent: SubtitleIntent, in tracks: [SubtitleTrack]) -> SubtitleTrack? {
        guard case let .track(language, forced, hearingImpaired, codec) = intent else { return nil }
        let candidates = tracks.filter { TrackLanguage.matches($0.language, language) && $0.isForced == forced }
        let flags = candidates.filter { $0.isHearingImpaired == hearingImpaired }
        return flags.first { MediaTrack.normalizedSubtitleCodec($0.codec) == MediaTrack.normalizedSubtitleCodec(codec) }
            ?? flags.first ?? candidates.first
    }
}

// MARK: - Labels

/// How the pickers and their buttons name a track.
enum TrackLabels {
    /// "English" for "en", "eng" or "English".
    static func languageName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.count <= 3, let name = Locale(identifier: "en").localizedString(forLanguageCode: raw) { return name }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func subtitleFormat(_ codec: String?) -> String {
        switch MediaTrack.normalizedSubtitleCodec(codec) {
        case "srt": return "SRT"
        case "ass": return (codec?.lowercased() == "ssa") ? "SSA" : "ASS"
        case "pgs": return "PGS"
        case "dvdsub": return "VobSub"
        case "mov_text": return "MOV Text"
        case "webvtt": return "WebVTT"
        case "dvb_subtitle": return "DVB"
        case "unknown": return "Subtitles"
        case let other: return other.uppercased()
        }
    }

    /// "English · TrueHD Atmos 7.1", with a commentary's own title after it.
    static func audioRow(_ track: AudioTrack) -> String {
        var parts = [languageName(track.language) ?? "Unknown", audioFormat(track)]
        if let title = track.title, !title.isEmpty,
           title.localizedCaseInsensitiveContains("comment") || title.localizedCaseInsensitiveContains("descri") {
            parts.append(title)
        }
        return parts.joined(separator: " · ")
    }

    /// "English 5.1" for the button.
    static func audioButton(_ track: AudioTrack) -> String {
        let layout = channelLayout(track)
        return [languageName(track.language) ?? "Audio", layout].compactMap { $0 }.joined(separator: " ")
    }

    /// "English · SRT", "English · PGS · Forced", "English SDH · SRT".
    static func subtitleRow(_ track: SubtitleTrack) -> String {
        var language = languageName(track.language) ?? "Unknown"
        if track.isHearingImpaired { language += " SDH" }
        var parts = [language, subtitleFormat(track.codec)]
        if track.isForced { parts.append("Forced") }
        return parts.joined(separator: " · ")
    }

    /// "English SRT" for the button.
    static func subtitleButton(_ track: SubtitleTrack) -> String {
        [languageName(track.language) ?? "Subtitles", track.isForced ? "Forced" : subtitleFormat(track.codec)]
            .joined(separator: " ")
    }

    /// Rows that would read alike ("English · PGS" twice: full and signs)
    /// gain the track's own title from the file.
    static func distinct(_ rows: [String], titles: [String?]) -> [String] {
        let counts = Dictionary(rows.map { ($0, 1) }, uniquingKeysWith: +)
        return zip(rows, titles).map { row, title in
            guard counts[row, default: 0] > 1, let title = title?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty, !row.localizedCaseInsensitiveContains(title) else { return row }
            return row + " · " + title
        }
    }

    /// "TrueHD Atmos 7.1": the codec, Atmos, then the layout.
    static func audioFormat(_ track: AudioTrack) -> String {
        let label = track.qualityLabel
        let atmos = label.hasSuffix(" Atmos")
        let base = atmos ? String(label.dropLast(" Atmos".count)) : label
        guard atmos else { return base }
        if let layout = channelLayout(track), base.hasSuffix(" " + layout) {
            return base.dropLast(layout.count + 1) + " Atmos " + layout
        }
        return base + " Atmos"
    }

    private static func channelLayout(_ track: AudioTrack) -> String? {
        let label = track.qualityLabel.replacingOccurrences(of: " Atmos", with: "")
        return label.split(separator: " ").last.map(String.init).flatMap { $0.contains(".") ? $0 : nil }
    }
}

extension AudioIntent {
    /// The shape of a detail page's track, kept for its title.
    init(from track: AudioTrack) {
        self.init(language: TrackLanguage.normalize(track.language), codec: track.codec, channels: track.channels)
    }
}

extension SubtitleIntent {
    init(from track: SubtitleTrack) {
        self = .track(language: TrackLanguage.normalize(track.language), forced: track.isForced,
                      hearingImpaired: track.isHearingImpaired, codec: track.codec)
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleSearch.swift
//  Rivulet
//
//  Plex's own subtitle search, as the player's Subtitles menu and the detail
//  page's Subtitles picker use it. The server searches its configured
//  subtitle sources (`GET /library/metadata/<id>/subtitles?language=`) and a
//  pick is saved next to the media (`PUT …?key=`), so it becomes one of the
//  file's own subtitle streams on that server, for every client.
//
//  Saving a file next to the media is the server admin's right, so search is
//  offered only where the account administers the server (`/accounts`
//  answers 200), never on a shared server, and never to a restricted profile.
//

import Foundation

@MainActor
enum SubtitleSearch {
    /// Admin answers per server URL + token, for the session.
    private static var adminAnswers: [String: Bool] = [:]

    /// The answer already known for a server, nil before the first ask.
    static func knownAccess(serverURL: String, token: String) -> Bool? {
        guard PlexUserProfileManager.shared.selectedUser?.restricted != true else { return false }
        return adminAnswers[serverURL + token]
    }

    /// One ask per server at a time.
    private static var asking: [String: Task<Bool, Never>] = [:]

    static func canSearch(serverURL: String, token: String) async -> Bool {
        if let known = knownAccess(serverURL: serverURL, token: token) { return known }
        let key = serverURL + token
        if let task = asking[key] { return await task.value }
        let task = Task { await PlexNetworkManager.shared.canAdministerServer(serverURL: serverURL, authToken: token) }
        asking[key] = task
        let isAdmin = await task.value
        asking[key] = nil
        adminAnswers[key] = isAdmin
        return isAdmin
    }

    /// The subtitle preference's language, else the device's, as ISO 639-1.
    static var language: String {
        let device = Locale.current.language.languageCode?.identifier(.alpha2) ?? "en"
        guard case .track(let preferred, _, _, _) = TrackIntentStore.subtitleIntent ?? .off else { return device }
        let code = TrackLanguage.normalize(preferred)
        return code.isEmpty ? device : Locale.LanguageCode(code).identifier(.alpha2) ?? device
    }

    static func search(serverURL: String, token: String, ratingKey: String) async throws -> [PlexStream] {
        try await PlexNetworkManager.shared.searchSubtitles(
            serverURL: serverURL, authToken: token, ratingKey: ratingKey, language: language)
    }

    /// A result's name, and its language, format and flags.
    static func title(of result: PlexStream) -> String {
        result.title ?? result.displayTitle ?? "Subtitle"
    }

    static func detail(of result: PlexStream) -> String {
        [result.language, result.codec?.uppercased(),
         result.hearingImpaired == true ? "SDH" : nil,
         result.forced == true ? "Forced" : nil]
            .compactMap { $0 }.joined(separator: " • ")
    }

    /// Saves `result` next to the media, then waits for the server to list it
    /// (about two seconds later, under a new id). `media` picks the version
    /// the caller describes from the refreshed item; `known` is the subtitle
    /// ids it already had. nil when it never arrived or `stillWanted` turned false.
    static func download(_ result: PlexStream, serverURL: String, token: String, ratingKey: String,
                         known: Set<Int>, media: ([PlexMedia]) -> [PlexMedia],
                         stillWanted: () -> Bool = { true }) async throws -> (stream: PlexStream, media: [PlexMedia])? {
        guard let resultKey = result.key else { return nil }
        let network = PlexNetworkManager.shared
        try await network.downloadSubtitle(serverURL: serverURL, authToken: token, ratingKey: ratingKey,
                                           resultKey: resultKey)
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1.5))
            let fresh = try await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            guard stillWanted() else { return nil }
            let picked = media(fresh.Media ?? [])
            if let added = picked.first?.Part?.first?.Stream?.first(where: {
                $0.isSubtitle && $0.key != nil && !known.contains($0.id)
            }) {
                return (added, picked)
            }
        }
        return nil
    }
}

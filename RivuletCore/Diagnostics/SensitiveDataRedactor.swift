// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SensitiveDataRedactor.swift
//  Rivulet
//
//  Strips credentials out of anything on its way to a diagnostics sink.
//
//  Plex authenticates with `X-Plex-Token` as a URL QUERY PARAMETER, not a
//  header, so any URL we log or attach to an error event carries a working
//  credential for that user's Plex account. IPTV/Xtream providers are worse:
//  their M3U and EPG URLs commonly carry `username`/`password` in the query,
//  and their stream URLs carry them in the PATH. The server's address is
//  stripped too: it is the user's home IP, or a plex.direct name embedding it.
//
//  Two things reach Sentry, and both need covering:
//    1. Values we attach ourselves (`scope.setExtra(url.absoluteString, ...)`).
//    2. Events the SDK builds itself — `enableCaptureFailedRequests` attaches
//       the failing request URL, and NSError descriptions embed the URL too.
//  Call sites can only fix (1), so the real guarantee is the `beforeSend` hook
//  in RivuletApp, which runs this over every outgoing event. Call sites are
//  still cleaned up so we don't ship secrets to a sink that merely scrubs them.
//
//  `nonisolated` to match SentryBridge: this runs on the error path from any
//  isolation context and must not cost an actor hop.
//

import Foundation

nonisolated enum SensitiveDataRedactor {

    /// Substituted for any value that would otherwise carry a credential.
    static let redactedValue = "[redacted]"

    /// Query-parameter names whose VALUES are secrets. Matched case-insensitively.
    /// `X-Plex-Token` is the Plex account/server token; the rest are the common
    /// IPTV/Xtream credential and session parameter names.
    private static let secretQueryKeys = [
        "x-plex-token",
        "password",
        "username",
        "token",
        "auth",
        "authorization",
        "api_key",
        "apikey",
        "access_token",
    ]

    /// Matches `key=value` in a query string for any key in `secretQueryKeys`.
    /// Value runs to the next `&`, `"`, whitespace, or end — NSError and Sentry
    /// bodies embed URLs inside prose, so we can't assume a clean terminator.
    private static let secretPattern: NSRegularExpression? = {
        let keys = secretQueryKeys
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "(?<key>\(keys))=(?<value>[^&\\s\"'<>]*)",
            options: [.caseInsensitive]
        )
    }()

    /// Substituted for the host of a user's own server (Plex, Jellyfin, IPTV,
    /// Dispatcharr). A server address is the user's home IP or a plex.direct
    /// name that embeds it, so it never leaves the device either.
    static let redactedHost = "[server]"

    /// Public services every user talks to. Their names identify no one and say
    /// which API failed, so they survive the scrub. Everything else is a server
    /// the user configured.
    private static let publicHostSuffixes = [
        "plex.tv",
        "themoviedb.org",
        "tmdb.org",
        "introdb.app",
    ]
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Matches a URL's scheme and authority (`userinfo@host:port`).
    private static let authorityPattern = try? NSRegularExpression(
        pattern: "\\b([a-z][a-z0-9+.-]*://)([^/\\s\"'<>?#]+)",
        options: [.caseInsensitive]
    )

    /// Xtream stream paths put the account in the path:
    /// `/live/<user>/<pass>/<id>.ts`, and the short form `/<user>/<pass>/<id>.ts`.
    private static let xtreamPrefixedPattern = try? NSRegularExpression(
        pattern: "/(live|movie|series|timeshift)/[^/\\s\"'<>?#]+/[^/\\s\"'<>?#]+/",
        options: [.caseInsensitive]
    )
    private static let xtreamShortPattern = try? NSRegularExpression(
        pattern: "^/[^/]+/[^/]+/(\\d+\\.(?:ts|m3u8|mp4|mkv|avi))$",
        options: [.caseInsensitive]
    )

    /// Server names and addresses outside a URL: plex.direct names (which embed
    /// the server's IP) and bare IPv4 literals.
    private static let plexDirectPattern = try? NSRegularExpression(
        pattern: "\\b[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.plex\\.direct\\b",
        options: [.caseInsensitive]
    )
    private static let ipv4Pattern = try? NSRegularExpression(
        pattern: "(?<![\\d.])(?:\\d{1,3}\\.){3}\\d{1,3}(?![\\d.])"
    )

    /// Returns `text` with every credential-bearing query value, server
    /// address and Xtream account path replaced.
    ///
    /// Key names are preserved (`X-Plex-Token=[redacted]`) so events stay
    /// diagnosable — we can still see WHICH parameters a failing request carried,
    /// just not their values. Ports survive too (32400 vs 443 is diagnostic).
    static func redact(_ text: String) -> String {
        var result = text
        if let secretPattern {
            result = secretPattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1=\(redactedValue)"
            )
        }
        result = replaceAuthorities(in: result)
        if let xtreamPrefixedPattern {
            result = xtreamPrefixedPattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "/$1/\(redactedValue)/\(redactedValue)/"
            )
        }
        for pattern in [plexDirectPattern, ipv4Pattern].compactMap({ $0 }) {
            result = pattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: redactedHost
            )
        }
        return result
    }

    /// A host safe to send: a public service or loopback as is, anything else
    /// as `[server]`.
    static func safeHost(_ host: String?) -> String {
        guard let host = host?.lowercased(), !host.isEmpty else { return "unknown" }
        if loopbackHosts.contains(host) { return host }
        let isPublic = publicHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        return isPublic ? host : redactedHost
    }

    /// A URL path with any Xtream account segments replaced.
    static func safePath(_ path: String) -> String {
        if let xtreamShortPattern {
            let range = NSRange(path.startIndex..., in: path)
            if xtreamShortPattern.firstMatch(in: path, range: range) != nil {
                return xtreamShortPattern.stringByReplacingMatches(
                    in: path, range: range,
                    withTemplate: "/\(redactedValue)/\(redactedValue)/$1"
                )
            }
        }
        guard let xtreamPrefixedPattern else { return path }
        return xtreamPrefixedPattern.stringByReplacingMatches(
            in: path,
            range: NSRange(path.startIndex..., in: path),
            withTemplate: "/$1/\(redactedValue)/\(redactedValue)/"
        )
    }

    /// Rewrites every URL authority in `text`: userinfo dropped, host through
    /// `safeHost`, port kept. Walks matches back to front so ranges stay valid.
    private static func replaceAuthorities(in text: String) -> String {
        guard let authorityPattern else { return text }
        var result = text
        let matches = authorityPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let authorityRange = Range(match.range(at: 2), in: result) else { continue }
            var authority = String(result[authorityRange])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            var host = authority
            var port = ""
            if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                host = String(authority[authority.index(after: authority.startIndex)..<close])
                port = String(authority[authority.index(after: close)...])
            } else if let colon = authority.lastIndex(of: ":") {
                host = String(authority[..<colon])
                port = String(authority[colon...])
            }
            result.replaceSubrange(authorityRange, with: safeHost(host) + port)
        }
        return result
    }

    /// Optional-preserving variant. Deliberately NOT an overload of `redact`:
    /// with both a `String` and a `String?` overload in scope, a call whose
    /// argument is itself generic (e.g. `String(x.prefix(500))`) can't pick one
    /// and fails to typecheck.
    static func redactOptional(_ text: String?) -> String? {
        text.map(redact)
    }

    /// A log-safe rendering of a URL: scheme, host (through `safeHost`), port,
    /// and path, with Xtream account segments and every query value removed.
    ///
    /// Prefer this over `url.absoluteString` at every diagnostics call site.
    static func safeURLString(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redact(url.absoluteString)
        }
        var base = ""
        if let scheme = components.scheme { base += "\(scheme)://" }
        base += safeHost(components.host)
        if let port = components.port { base += ":\(port)" }
        base += safePath(components.path)

        guard let items = components.queryItems, !items.isEmpty else { return base }
        // Keep the shape of the query (which params were sent) without values.
        // Plex transcode failures are diagnosed from WHICH profile params were
        // present, never from the token.
        let keys = items.map(\.name).joined(separator: ",")
        return "\(base)?[\(keys)]"
    }

    /// Optional variant, named distinctly for the same reason as
    /// `redactOptional`. Renders a missing URL as `"unknown"`.
    static func safeURLStringOptional(_ url: URL?) -> String {
        url.map(safeURLString) ?? "unknown"
    }
}

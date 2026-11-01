// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ConnectionAlert.swift
//  Rivulet
//
//  How the app says "the server is gone". Cached content keeps rendering and
//  we tell the user once, with the app's standard popup card.
//
//  This replaces `ConnectionErrorBannerView`, which reserved 120pt of
//  `contentInset.top` on the home. The connection check resolves a second or
//  two after content renders, so every row jumped down 120pt mid-session, and
//  its Retry button was a focusable island floating outside the collection
//  view. A modal costs the layout nothing.
//
//  Two entry points:
//  - `presentOnceIfOffline` — unprompted, once per outage.
//  - `allowPlayback` — gates the one thing that genuinely cannot work from
//    cache. Browsing cached metadata is fine and is deliberately not gated.
//

import UIKit

/// Once-per-outage gate for the unprompted popup. A pure value type so the
/// state machine is testable without a device.
struct ConnectionAlertGate {

    private(set) var hasShown = false

    /// True the first time we go offline, then false while we stay offline —
    /// a flapping connection must not stack popups. Reconnecting re-arms it,
    /// so a second outage later in the session is announced again.
    mutating func shouldPresent(isConnected: Bool) -> Bool {
        if isConnected {
            hasShown = false
            return false
        }
        guard !hasShown else { return false }
        hasShown = true
        return true
    }
}

@MainActor
enum ConnectionAlert {

    private static var gate = ConnectionAlertGate()

    /// Unprompted popup for a connection that just dropped. No-op while
    /// connected, while signed out (`HomeStateView.notConnected` covers that
    /// case with its own full-screen prompt), or once this outage has already
    /// been announced.
    static func presentOnceIfOffline(from presenter: UIViewController) {
        let auth = PlexAuthManager.shared
        guard auth.hasCredentials else { return }
        guard gate.shouldPresent(isConnected: isMainServerReachable) else { return }
        present(from: presenter, retry: nil)
    }

    /// The offline card on demand (a card for a title on the server that is down).
    static func presentOffline(from presenter: UIViewController) {
        present(from: presenter, retry: nil)
    }

    /// The main server answers: its launch check passed and it has not gone
    /// quiet since (`MainServerHealth`).
    static var isMainServerReachable: Bool {
        PlexAuthManager.shared.isConnected && !MainServerHealth.shared.isOffline
    }

    /// "Sesama is offline. Try Search or Watchlist.": the other servers and
    /// the account's own lists still work while the main one is down.
    static var offlineMessage: String {
        "\(serverName) is offline. Try Search or Watchlist."
    }

    static var serverName: String {
        PlexAuthManager.shared.mainServerName ?? PlexAuthManager.shared.savedServerName ?? "Your Plex server"
    }

    /// Gate for anything that needs a live server. Returns true when the
    /// caller may proceed; when offline it shows the popup and returns false.
    /// A Retry that reconnects runs `retry`, so the user doesn't have to find
    /// the item and press Play a second time.
    static func allowPlayback(from presenter: UIViewController,
                              retry: (() -> Void)? = nil) -> Bool {
        guard !isMainServerReachable else { return true }
        present(from: presenter, retry: retry)
        return false
    }

    private static func present(from presenter: UIViewController, retry: (() -> Void)?) {
        let host = presenter.topmostPresented
        // Never stack two of these — a flap and a double Play press both get here.
        guard !(host is ConfirmationPopupViewController) else { return }

        let popup = ConfirmationPopupViewController(
            title: "\(serverName) Is Offline",
            message: offlineMessage + " Recently loaded content is still here to browse.",
            confirmTitle: "Retry",
            cancelTitle: "OK",
            onConfirm: { retryConnection(from: presenter, then: retry) }
        )
        host.present(popup, animated: true)
    }

    /// `onConfirm` fires from the popup's dismiss completion, so the card is
    /// already gone by the time we get here and re-presenting on a failed
    /// retry is safe.
    private static func retryConnection(from presenter: UIViewController,
                                        then retry: (() -> Void)?) {
        Task { @MainActor in
            await PlexAuthManager.shared.verifyAndFixConnection()
            MainServerHealth.shared.probeSoon()
            try? await Task.sleep(for: .seconds(MainServerHealth.probeTimeout + 0.5))
            guard isMainServerReachable else {
                present(from: presenter, retry: retry)
                return
            }
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            retry?()
        }
    }
}

extension UIViewController {
    /// The controller actually on screen above this one. Presenting onto a
    /// covered controller silently does nothing.
    var topmostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

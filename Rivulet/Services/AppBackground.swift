// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AppBackground.swift
//  Rivulet
//
//  What leaving the foreground does, app-wide. tvOS freezes a backgrounded
//  app within seconds, and an Apple TV that goes to sleep keeps it frozen for
//  hours, so on the way out the app puts down everything that only serves the
//  screen:
//  - requests for the screen are cancelled and sent again on return
//    (`ForegroundGate`): Home's polls, the multi-server Continue Watching pass,
//    the library index, other servers' lookups and TMDB pick up where they were;
//  - decoded images are dropped (the originals stay on disk);
//  - the audio session is let go when nothing is playing.
//
//  The owners do the rest: Home's timers stop on resign-active
//  (`PlexDataStore`), the video player pauses and reports its position
//  (`UniversalPlayerViewModel`), and Live TV closes and releases its tuner
//  (`LiveTVAetherPlayerViewController`, `LiveMultiviewViewController`).
//

import UIKit

enum AppBackground {

    static func install() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                           queue: .main) { _ in
            MainActor.assumeIsolated { enterBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                           queue: .main) { _ in
            ForegroundGate.shared.enterForeground()
        }
    }

    private static func enterBackground() {
        ForegroundGate.shared.enterBackground()
        ImageCacheManager.shared.emptyMemory()
        ContinueWatchingCardCompositor.emptyMemory()
        // A turn later, once Live TV's own observers have closed it. A song
        // keeps playing in the background, and a video player that is up
        // (paused by now) keeps the session for Play on return.
        DispatchQueue.main.async {
            let music = MusicQueue.shared
            guard [.idle, .paused].contains(music.playbackState), !music.videoOwnsNowPlaying else { return }
            PlaybackAudioSessionConfigurator.deactivatePlaybackSession(owner: "AppBackground")
        }
    }
}

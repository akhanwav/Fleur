# Fleur fork notes

This file is specific to this fork (`akhanwav/Fleur`, personal Apple TV
build under its own Apple Developer team). It is **not** `CLAUDE.md`, which
documents the original Rivulet project and should stay as-is. Keep fork-only
context — what changed, what's still broken, what's next — here instead.

## What's changed so far

### Fork identity
- Bundle IDs: `com.gstudios.rivulet` → `com.akhanwav.fleur` (and the
  TopShelfExtension/tests variants), everywhere it appeared (project file,
  Keychain service strings, background session identifiers, CI config, perf
  scripts).
- App Group: `group.com.bain.Rivulet` → `group.com.akhanwav.fleur`.
- Code signing moved to this account's team (`DEVELOPMENT_TEAM`), with
  `CODE_SIGN_STYLE = Automatic` left in place.
- Fixed two expressions that time out type-checking on Xcode 26.3 (the repo's
  own CI is pinned to Xcode 27, which has a more patient type-checker) —
  `PersonFilmographyProvider.swift` and `LiveShelves.swift`. Purely mechanical
  splits into typed intermediate steps, no behavior change.

### Player tweaks
- Center click (Select, nothing else focused) now toggles play/pause, like
  Apple's TV app, instead of just toggling the chrome.
- Left/Right skip now briefly flashes the progress bar (playhead + time) even
  with the chrome hidden, reusing the existing seek-indicator lifecycle. The
  centered skip icon and the progress-bar flash now have independent
  durations (icon ~1s, bar ~2s).
- Default subtitle position moved down (~2 lines total across a few passes)
  and the default subtitle font size reduced by ~2pt at 1080p.
- **Ambient pause removed.** Pause no longer hands off to a backdrop/poster
  presentation after 10s (or a dimmed variant after 2 minutes) — the real
  video frame stays up for the whole pause. Chrome still auto-fades after a
  few seconds of no input (now driven by the same controls-hide timer
  playback already used, since pause previously relied on ambient to do
  this). The full-frame pause dim overlay was also removed per later request;
  pause now shows the exact live frame, no overlay at all. The separate,
  smaller scrubber-local pause dim (`PlayerProgressBarView.setPausedDim`) is
  untouched.

### Audio Sync (new feature)
A user-adjustable audio/video sync offset, in 10ms steps, backed by
AetherEngine's own `setAudioDelay` (AE#464):
- One **global** value (not per-title) — set in Settings → Playback, or live
  from the player's Audio panel; both read/write the same stored value.
- In the Audio panel, the Sync row is itself focusable: Left/Right step the
  offset directly (hold to repeat-accelerate), covering both discrete-press
  remotes and touch-surface/iPhone-Remote swipes.
- Changes are debounced (1.5s after the last press) before actually reaching
  the engine, with a transient "Applying…" state shown during the reload.
  "Applying…" clears based on observing the reload's own buffering settle
  back to playing/paused (not just a fixed timer — a timer is only the
  fallback for a reload fast enough to never visibly buffer).
- aether route only — AVPlayer's `hls` route has no audio-delay hook at all;
  the stepper hides itself there.
- Fixed along the way: a stall-tracker false positive where two audio-sync
  reloads within a minute could trip Rivulet's own "Auto" quality step-down,
  which then killed the engine's own in-flight reload out from under it.
  `StallTracker` now has a `noteExpectedPause` escape hatch (like the
  existing one used around HLS seeks/switches) so an audio-sync reload isn't
  misread as a real stall.

### Plex / server-side
- `PlexAPI.clientIdentifier` moved from `UserDefaults` to the Keychain (with
  a one-time migration), so it survives a reinstall instead of minting a new
  "device" in Plex's Dashboard every time.
- The HLS transcode preflight and the `/decision` call now log the actual
  response body on a non-2xx status, not just the status code.
- Investigated (no code change) why an episode disappeared from Continue
  Watching after a hard app kill mid-playback: Rivulet reports progress to
  Plex every 10s while playing plus immediately on state changes, but there's
  no app-lifecycle hook that can flush a final report on a true hard kill —
  nothing can, the OS gives no code-execution window for that. Separately,
  `reportFinalProgress()` now skips reporting entirely when the player ends
  in `.failed`, so a broken session can't report a regressed/frozen position
  and overwrite the server's real one.

## Known issues (not fixed yet)

1. **Dolby Vision Profile 5 forced-transcode → HTTP 400.** Reproducible: cap
   the streaming quality (Settings → Home/Away Streaming Quality → any fixed
   Mbps step, not Original/Auto) and play a 4K Dolby Vision Profile 5 title —
   the HLS transcode fallback fails every time with a generic "400 Bad
   Request" page from Plex Media Server's own embedded web server (not an
   app-level Plex error — logged now, see above). The same cap against a
   1080p file or a non-DV 4K file works fine, and the request shape Rivulet
   sends is provably identical regardless of DV-ness (confirmed by reading
   `buildHLSDirectPlayURL`), so this isn't a parameter-construction bug on our
   side as far as we can tell. Leading theory: DV Profile 5 has no
   independently-viewable base layer (unlike 7/8), so converting it to plain
   SDR h264 needs dovi-aware tone-mapping the server's transcoder may not
   have. Not confirmed without Plex Media Server's own server-side logs at
   the failure timestamp.
2. **Pre-existing crash in `RivuletTests/Unit/Player/ProviderPlaybackSourceTests`.**
   About half the test cases in this file crash the test host when run via
   `xcodebuild test` in this sandboxed environment. Confirmed present on the
   commit *before* any work in this fork — not introduced by anything here,
   and not yet investigated further.
3. **Two features depend on the original developer's private infrastructure**
   and may not work under this fork's bundle ID/team:
   - TMDB-sourced artwork/metadata (Discover tab and rows, logos on Home/
     player chrome/media detail, person filmography, recommendations) — via
     `tmdb-proxy.baingurley.workers.dev`.
   - The in-player Insights cast/trivia panel — via
     `insights-api.baingurley.workers.dev`.
   Both go through App Attest (`AppAttestClient`), which binds the
   attestation to this app's actual team ID + bundle ID — the original
   developer's Workers likely only recognize their own. Failure is soft
   (requests just go out unattested and the Worker decides), so these
   features may simply not populate rather than crash anything.

## Planned next tasks

- Back-button fixes in the player (specifics TBD).
- Never let Auto quality step-down trigger for Dolby Vision Profile 5
  content, so the known transcode failure (#1 above) can't be reached
  automatically — only via an explicit manual quality cap, which at least
  stays predictable.
- Rename the app to "Fleur" with a fox icon (display name + icon asset work;
  bundle IDs/App Group/team are already done — this is the user-facing
  branding pass).
- Replace the TMDB proxy dependency with this account's own TMDB API key,
  removing the tie to the original developer's Worker for metadata/artwork.
- Further subtitle styling adjustments (beyond the position/size tweaks
  already made).

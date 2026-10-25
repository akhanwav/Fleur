// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DisplayCriteriaManager.swift
//  Rivulet
//
//  Manages tvOS display criteria for HDR/Dolby Vision content
//  Enables Match Frame Rate and Match Dynamic Range for Rivulet playback
//

import Foundation
import AVFoundation
import AVKit


/// Manages display criteria for HDR content playback
/// This enables tvOS "Match Content" (Frame Rate and Dynamic Range) for Rivulet playback
///
/// Note: Apple doesn't provide a public API to create AVDisplayCriteria manually.
/// The only way to obtain display criteria is from AVAsset.preferredDisplayCriteria.
/// This manager creates a temporary AVURLAsset to fetch the criteria from the stream.
@MainActor
final class DisplayCriteriaManager {

    static let shared = DisplayCriteriaManager()

    private var hasSetCriteria = false
    private var lastCriteriaWasHDR = false
    private var assetForCriteria: AVURLAsset?
    /// What `configureWithFormatDescription` wrote last, to skip an identical rewrite.
    private var lastSignature: String?
    private var lastWrittenCriteria: AVDisplayCriteria?

    private init() {}

    /// Whether the system will honor display criteria changes (Match Content enabled)
    var isDisplayCriteriaMatchingEnabled: Bool {
        getDisplayManager()?.isDisplayCriteriaMatchingEnabled ?? false
    }

    // MARK: - Public API

    /// Configure display criteria by fetching it from the stream URL
    /// This creates a temporary AVURLAsset to extract HDR/frame rate metadata
    /// Call this before starting playback to trigger Match Content
    /// - Parameters:
    ///   - url: The video stream URL
    ///   - headers: HTTP headers for authentication
    func configureFromURL(_ url: URL, headers: [String: String]? = nil) async {

        // Create asset with headers
        var options: [String: Any] = [:]
        if let headers = headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)
        self.assetForCriteria = asset  // Keep reference to prevent deallocation

        do {
            // Load the display criteria from the asset (tvOS 16+ API)
            let criteria = try await asset.load(.preferredDisplayCriteria)
            lastCriteriaWasHDR = false
            setDisplayCriteria(criteria)
        } catch {
            playerDebugLog("🖥️ DisplayCriteria: Failed to load display criteria: \(error.localizedDescription)")
            // Continue without display criteria - playback will still work, just without mode switching
        }
    }

    /// Configure display criteria using pre-built criteria from an AVAsset
    /// Use this if you already have an AVAsset (e.g., from preflight check)
    func configureFromAsset(_ asset: AVAsset) async {
        do {
            let criteria = try await asset.load(.preferredDisplayCriteria)
            lastCriteriaWasHDR = false
            setDisplayCriteria(criteria)
        } catch {
            playerDebugLog("🖥️ DisplayCriteria: Failed to load criteria from asset: \(error.localizedDescription)")
        }
    }

    /// Configure display criteria with known HDR type using a format description
    /// Creates a minimal format description to generate criteria
    /// - Parameters:
    ///   - frameRate: Target frame rate (e.g., 23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
    ///   - width: Video width
    ///   - height: Video height
    ///   - isDolbyVision: Whether content is Dolby Vision
    ///   - isHDR10: Whether content is HDR10/HDR10+
    ///   - isHLG: Whether content is HLG
    func configureWithFormatDescription(
        frameRate: Float,
        width: Int32,
        height: Int32,
        isDolbyVision: Bool = false,
        isHDR10: Bool = false,
        isHLG: Bool = false
    ) {
        // Create a format description with HDR metadata
        var formatDescription: CMFormatDescription?

        // Determine the codec type
        // Use DV-specific codec type (dvh1) for Dolby Vision to trigger DV display mode
        // HEVC for other HDR content, H.264 for SDR
        let codecType: CMVideoCodecType
        if isDolbyVision {
            codecType = 0x64766831 // 'dvh1' — Dolby Vision HEVC
        } else if isHDR10 || isHLG {
            codecType = kCMVideoCodecType_HEVC
        } else {
            codecType = kCMVideoCodecType_H264
        }

        // Build extensions dictionary for HDR metadata
        var extensions: [CFString: Any] = [:]

        // Set color primaries and transfer function based on HDR type
        if isDolbyVision || isHDR10 || isHLG {
            // BT.2020 color primaries for all HDR types
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020

            // YCbCr matrix
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020

            if isDolbyVision {
                // Dolby Vision uses PQ transfer function
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                // Add Dolby Vision configuration (Profile 5 is most common for streaming)
                // Note: This is a simplified representation
            } else if isHLG {
                // HLG transfer function
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            } else if isHDR10 {
                // HDR10 uses PQ (SMPTE ST 2084)
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            }
        } else {
        }

        // Create the format description
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else {
            playerDebugLog("🖥️ DisplayCriteria: Failed to create format description (status: \(status))")
            return
        }

        // Already active (a quality change, the next episode): rewriting it starts no
        // switch, and waitForDisplaySwitchIfNeeded would wait its full second for one.
        // AVDisplayCriteria exposes neither its rate nor its range, so this compares
        // what this manager wrote last, and only while the system still holds that
        // write: the engine's own criteria on the aether route always differ by object.
        let signature = "\(frameRate)|\(codecType)|\(isDolbyVision)|\(isHDR10)|\(isHLG)"
        if signature == lastSignature, let written = lastWrittenCriteria,
           getDisplayManager()?.preferredDisplayCriteria === written {
            hasSetCriteria = false
            return
        }

        // Create display criteria from format description
        let criteria = AVDisplayCriteria(refreshRate: frameRate, formatDescription: formatDesc)
        lastCriteriaWasHDR = isDolbyVision || isHDR10 || isHLG
        setDisplayCriteria(criteria)
        lastSignature = signature
        lastWrittenCriteria = criteria
    }

    /// Wait for tvOS to finish the HDMI mode switch a criteria write started, so
    /// the first frames do not land on a panel mid-handshake. AVPlayerViewController
    /// gets this internally; a bare AVPlayer does not.
    ///
    /// Driven by the mode-switch notifications, armed before the write
    /// (`setDisplayCriteria`), because a switch can start before this runs. It
    /// used to return as soon as the screen showed HDR headroom after an HDR
    /// write, which is right for a range switch and wrong for a rate one: with
    /// the home screen already in HDR, a 24 fps transcode started its first
    /// frames 25 ms after the write, while the panel was still leaving 60 Hz.
    func waitForDisplaySwitchIfNeeded() async {
        guard hasSetCriteria, let displayManager = getDisplayManager(),
              displayManager.isDisplayCriteriaMatchingEnabled else { return }

        // A write the panel is already in starts nothing; give a real one 1 s to begin.
        var waitedMs = 0
        while !switchStarted && !displayManager.isDisplayModeSwitchInProgress && waitedMs < 1000 {
            try? await Task.sleep(for: .milliseconds(20))
            waitedMs += 20
        }
        guard switchStarted || displayManager.isDisplayModeSwitchInProgress else {
            playerDebugLog("🖥️ DisplayCriteria: no mode switch started within 1000ms")
            return
        }

        // Until the end notification, or until a switch seen in progress stops being one.
        var sawInProgress = displayManager.isDisplayModeSwitchInProgress
        while !switchEnded {
            let inProgress = displayManager.isDisplayModeSwitchInProgress
            if sawInProgress && !inProgress { break }
            sawInProgress = sawInProgress || inProgress
            if waitedMs >= 6000 {
                playerDebugLog("🖥️ DisplayCriteria: display-mode switch did not settle within 5s")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
            waitedMs += 50
        }
        playerDebugLog("🖥️ DisplayCriteria: mode switch settled after ~\(waitedMs)ms")
    }

    private var switchStarted = false
    private var switchEnded = false
    private var switchObservers: [NSObjectProtocol] = []

    /// Listen for the switch this write is about to start.
    private func armSwitchObservation() {
        switchObservers.forEach(NotificationCenter.default.removeObserver)
        switchStarted = false
        switchEnded = false
        let center = NotificationCenter.default
        switchObservers = [
            // object nil: tvOS posts these from a shared display manager, not the
            // window's (measured by AetherEngine on an Apple TV 4K, tvOS 26.5).
            center.addObserver(forName: .AVDisplayManagerModeSwitchStart,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.switchStarted = true }
            },
            center.addObserver(forName: .AVDisplayManagerModeSwitchEnd,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.switchEnded = true }
            },
        ]
    }

    /// Reset display criteria to default (SDR, system frame rate)
    /// Call this when playback ends
    ///
    /// Unconditional on purpose, and it has to stay that way. This used to be
    /// gated on `hasSetCriteria`, which is only ever true when *this* manager did
    /// the writing, and on the aether route it never does: AetherEngine owns that
    /// handshake (only the `hls` transcode route configures here). So the early reset the player exit
    /// fires at fade start was a silent no-op, and the only real nil write was the
    /// engine's own inside `engine.stop()`, reached from `stopPlayback()` off
    /// SwiftUI `.onDisappear` — i.e. after the modal is already gone. The ~1s HDMI
    /// renegotiation therefore played out on the freshly revealed home screen no
    /// matter how long the exit fade ran (#249). Writing nil here regardless is
    /// what actually starts the handshake behind the black plate; the engine's
    /// later write is then nil onto nil.
    ///
    /// Both callers are teardown paths, so there is no in-flight `apply()` on the
    /// engine side for this write to race.
    ///
    /// - Returns: whether criteria were actually dropped, i.e. whether an HDMI
    ///   renegotiation is now incoming. False covers Match Content being off
    ///   (the engine's `apply()` guards on `isDisplayCriteriaMatchingEnabled` and
    ///   writes nothing at all, so there is nothing to release), a route that
    ///   never programmed the panel, and the second of two resets in one exit.
    ///   The player exit fade is gated on this so users who get no handshake do
    ///   not pay for a mask they do not need.
    @discardableResult
    func reset() -> Bool {
        hasSetCriteria = false
        lastCriteriaWasHDR = false
        assetForCriteria = nil  // Release the asset
        lastSignature = nil
        lastWrittenCriteria = nil

        guard let displayManager = getDisplayManager() else {
            playerDebugLog("🖥️ DisplayCriteria: No display manager available for reset")
            return false
        }
        guard displayManager.preferredDisplayCriteria != nil else {
            playerDebugLog("🖥️ DisplayCriteria: reset — panel already at default, no handshake expected")
            return false
        }

        displayManager.preferredDisplayCriteria = nil
        playerDebugLog("🖥️ DisplayCriteria: reset — criteria released, HDMI handshake starts now")
        return true
    }

    // MARK: - Convenience Methods

    /// Configure display criteria from Plex video stream metadata
    /// Uses format description from Plex metadata (instant, no network request)
    /// This is the preferred method as it adds zero latency to playback start
    /// Works for ALL content - SDR gets frame rate matching, HDR/DV gets dynamic range matching too
    /// - Parameters:
    ///   - videoStream: The video stream metadata from Plex
    ///   - forceHDR10Fallback: If true, treat Dolby Vision content as HDR10 instead
    func configureForContent(videoStream: PlexStream?, forceHDR10Fallback: Bool = false) {
        guard let stream = videoStream, stream.isVideo else {
            playerDebugLog("🖥️ DisplayCriteria: No video stream metadata available")
            return
        }

        let frameRate = Float(stream.frameRate ?? 24.0)
        let width = Int32(stream.width ?? 1920)
        let height = Int32(stream.height ?? 1080)

        // Optionally strip Dolby Vision to an HDR10 fallback.
        // Check if base layer is HDR10 compatible (BL Compat ID 1 or 4)
        let blCompatID = stream.DOVIBLCompatID
        let hasHDR10Base = blCompatID == 1 || blCompatID == 4

        let isDV: Bool
        let isHDR: Bool
        let isHLG = stream.colorTrc?.lowercased().contains("hlg") == true ||
                    stream.colorTrc?.lowercased().contains("arib-std-b67") == true

        if forceHDR10Fallback && stream.isDolbyVision {
            // Use HDR10 if the base layer is compatible, otherwise SDR.
            isDV = false
            isHDR = hasHDR10Base || stream.isHDR
            playerDebugLog("🖥️ DisplayCriteria: DV fallback active - using \(isHDR ? "HDR10" : "SDR") (BL CompatID: \(blCompatID ?? -1))")
        } else {
            isDV = stream.isDolbyVision
            isHDR = stream.isHDR && !isDV
        }

        // Log what we're configuring
        let dynamicRange = isDV ? "Dolby Vision" : isHLG ? "HLG" : isHDR ? "HDR10" : "SDR"
        playerDebugLog("🖥️ DisplayCriteria: Configuring for \(dynamicRange) @ \(frameRate)fps (\(width)x\(height))")

        configureWithFormatDescription(
            frameRate: frameRate,
            width: width,
            height: height,
            isDolbyVision: isDV,
            isHDR10: isHDR,
            isHLG: isHLG
        )
    }

    /// Configure display criteria by fetching from stream URL
    /// Note: This adds latency as it requires a network request - use configureForContent(videoStream:) instead
    func configureForContentFromURL(
        url: URL,
        headers: [String: String]?,
        videoStream: PlexStream?
    ) async {
        // Try to get criteria from URL (most accurate but slow)
        await configureFromURL(url, headers: headers)

        // If URL-based approach failed, fall back to metadata
        if !hasSetCriteria {
            configureForContent(videoStream: videoStream)
        }
    }

    // MARK: - Private Helpers

    /// Set display criteria on the display manager
    private func setDisplayCriteria(_ criteria: AVDisplayCriteria) {
        guard let displayManager = getDisplayManager() else {
            playerDebugLog("🖥️ DisplayCriteria: No display manager available")
            return
        }

        armSwitchObservation()
        displayManager.preferredDisplayCriteria = criteria
        hasSetCriteria = true

        // Log the display manager state
        if displayManager.isDisplayCriteriaMatchingEnabled {
        } else {
            playerDebugLog("🖥️ DisplayCriteria: ⚠️ Display criteria matching is DISABLED in system settings")
            playerDebugLog("🖥️ DisplayCriteria: User should enable 'Match Content' in Settings > Video and Audio")
        }
    }

    /// Get the display manager from the key window
    private func getDisplayManager() -> AVDisplayManager? {
        getKeyWindow()?.avDisplayManager
    }

    private func getKeyWindow() -> UIWindow? {
        // On tvOS, get the key window's display manager
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            playerDebugLog("🖥️ DisplayCriteria: Could not find window")
            return nil
        }

        #if targetEnvironment(simulator)
        // avDisplayManager category may not load on the simulator (no real display hardware)
        guard window.responds(to: Selector(("avDisplayManager"))) else {
            playerDebugLog("🖥️ DisplayCriteria: avDisplayManager not available on simulator")
            return nil
        }
        #endif

        return window
    }
}

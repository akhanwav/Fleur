// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherVideoSurfaceView.swift
//  Rivulet
//
//  SwiftUI wrapper for AetherEngine's render surface (`AetherPlayer.makeRenderSurface`).
//  The engine attaches whichever CALayer the active backend uses —
//  AVPlayerLayer on the native loopback-HLS path, or
//  AVSampleBufferDisplayLayer on the software path (AV1 / VP9 / MPEG-2 /
//  VC-1 / MPEG-4 Part 2) — and re-attaches it across internal session
//  swaps (audio-track switch, background reopen). Hosting this view is
//  the only correct way to display Aether video: binding an
//  AVPlayerLayer to `currentAVPlayer` covers the native backend only.
//
//  The surface is a plain UIKit container: the engine's view, and above it
//  the picture held across a background return (`AetherPlayer.heldFrame`).
//  The still is a sibling view, not a subview of the engine's: the engine
//  adds its layer to its own view on every rebuild, which would put the
//  video back on top of anything added there first.
//

import AVFoundation
import Combine
import SwiftUI

struct AetherVideoSurfaceView: UIViewRepresentable {
    let player: AetherPlayer
    /// The title's background art, held over the video for an HDR or Dolby
    /// Vision title on a background return (`AetherPlayer.HeldPicture.artwork`).
    var artwork: UIImage?

    func makeUIView(context: Context) -> AetherSurfaceContainerView {
        let view = AetherSurfaceContainerView()
        view.artwork = artwork
        view.attach(player)
        return view
    }

    func updateUIView(_ uiView: AetherSurfaceContainerView, context: Context) {
        uiView.artwork = artwork
        uiView.attach(player)
    }

    static func dismantleUIView(_ uiView: AetherSurfaceContainerView, coordinator: ()) {
        uiView.detach()
    }
}

@MainActor
final class AetherSurfaceContainerView: UIView {
    private let playerView = AetherPlayer.makeRenderSurface()
    private let stillView = UIImageView()
    private weak var boundPlayer: AetherPlayer?
    private var heldFrameCancellable: AnyCancellable?
    var artwork: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for view in [playerView, stillView] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        stillView.isUserInteractionEnabled = false
        stillView.isHidden = true
        stillView.clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ player: AetherPlayer) {
        guard boundPlayer !== player else { return }
        detach()
        player.bind(surface: playerView)
        boundPlayer = player
        heldFrameCancellable = player.$heldFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] frame in
                self?.showHeldFrame(frame, gravity: player?.videoGravity ?? .resizeAspect)
            }
    }

    func detach() {
        heldFrameCancellable = nil
        boundPlayer?.unbind(surface: playerView)
        boundPlayer = nil
        showHeldFrame(nil, gravity: .resizeAspect)
    }

    private func showHeldFrame(_ picture: AetherPlayer.HeldPicture?, gravity: AVLayerVideoGravity) {
        switch picture {
        case .frame(let frame):
            stillView.image = UIImage(cgImage: frame)
            switch gravity {
            case .resizeAspectFill: stillView.contentMode = .scaleAspectFill
            case .resize: stillView.contentMode = .scaleToFill
            default: stillView.contentMode = .scaleAspectFit
            }
        case .artwork:
            // Art is not the video's frame: it fills the screen, as on the
            // player's loading screen.
            stillView.image = artwork
            stillView.contentMode = .scaleAspectFill
        case nil:
            stillView.image = nil
        }
        stillView.isHidden = stillView.image == nil
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionTagsView.swift
//  Rivulet
//
//  The quality and server of one search result ("4K DV", "Angel"), as two
//  Continue Watching tags side by side. Search lists every copy of a title as
//  its own result, so a 4K and a 1080p copy read as duplicates without them.
//

import UIKit

@MainActor
final class VersionTagsView: UIStackView {
    private let qualityTag = QualityTagView()
    private let serverTag = QualityTagView()
    private var qualityTask: Task<Void, Never>?
    private var shownRef: MediaItemRef?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        spacing = 6
        alignment = .center
        isUserInteractionEnabled = false
        qualityTag.isHidden = true
        serverTag.isHidden = true
        // A long server name truncates before the quality does.
        qualityTag.setContentCompressionResistancePriority(.required, for: .horizontal)
        serverTag.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(qualityTag)
        addArrangedSubview(serverTag)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Tags `item`: its server now, its quality once `TitleQuality` has read
    /// the title's detail (cached for the session, so a revisit is instant).
    func show(item: MediaItem) {
        let ref = item.ref
        serverTag.text = PlexHomeViewController.serverName(
            providerID: ref.providerID, kind: ref.isJellyfin ? .jellyfin : .plex)
        serverTag.isHidden = false
        // Already showing, or still reading, this title's quality.
        guard ref != shownRef else { return }
        shownRef = ref
        qualityTask?.cancel()
        qualityTask = nil
        if let known = TitleQuality.known(for: ref) {
            setQuality(known)
            return
        }
        setQuality(nil)
        qualityTask = Task { [weak self] in
            let label = await TitleQuality.label(for: ref)
            guard !Task.isCancelled, let self, self.shownRef == ref else { return }
            self.setQuality(label)
            self.qualityTask = nil
        }
    }

    func clear() {
        qualityTask?.cancel()
        qualityTask = nil
        shownRef = nil
        setQuality(nil)
        serverTag.text = nil
        serverTag.isHidden = true
    }

    func setFocused(_ focused: Bool) {
        qualityTag.setFocused(focused)
        serverTag.setFocused(focused)
    }

    private func setQuality(_ label: String?) {
        qualityTag.text = label
        qualityTag.isHidden = label == nil
    }
}

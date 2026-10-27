// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionTagsView.swift
//  Rivulet
//
//  The quality and servers of one search result ("4K DV", "Sesama +2"), as
//  Continue Watching tags side by side. Search lists every copy of a title as
//  its own result, so a 4K and a 1080p copy read as duplicates without them.
//

import UIKit

@MainActor
final class VersionTagsView: UIStackView {
    private let qualityTag = QualityTagView()
    private let serverTag = QualityTagView()
    private let showsServers: Bool
    private var qualityTask: Task<Void, Never>?
    private var serverRequest: ServerCopyCounts.Request?
    private var shownRef: MediaItemRef?

    /// `showsServers` false keeps only the quality (Recently Searched).
    init(showsServers: Bool = true) {
        self.showsServers = showsServers
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 6
        alignment = .center
        isUserInteractionEnabled = false
        qualityTag.isHidden = true
        serverTag.isHidden = true
        // A long server name truncates before the quality does.
        qualityTag.setTextCompressionResistance(.required)
        serverTag.setTextCompressionResistance(.defaultLow)
        addArrangedSubview(qualityTag)
        addArrangedSubview(serverTag)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Tags `item`: its server now, its quality once `TitleQuality` has read
    /// the title's detail, and "+N" once its Ways to Watch lookup has asked
    /// the other servers. Both answers are cached for the session.
    func show(item: MediaItem) {
        let ref = item.ref
        // Already showing, or still reading, this title.
        guard ref != shownRef else { return }
        clear()
        shownRef = ref
        if showsServers { showServers(for: item) }
        if let known = TitleQuality.known(for: ref) {
            setQuality(known)
            return
        }
        qualityTask = Task { [weak self] in
            let label = await TitleQuality.label(for: item)
            guard !Task.isCancelled, let self, self.shownRef == ref else { return }
            self.setQuality(label)
            self.qualityTask = nil
        }
    }

    /// A fixed label in the quality tag's place, nothing looked up.
    func showLabel(_ text: String) {
        clear()
        setQuality(text)
    }

    func clear() {
        qualityTask?.cancel()
        qualityTask = nil
        serverRequest?.cancel()
        serverRequest = nil
        shownRef = nil
        setQuality(nil)
        serverTag.text = nil
        serverTag.suffix = nil
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

    private func showServers(for item: MediaItem) {
        let name = PlexHomeViewController.serverName(
            providerID: item.ref.providerID, kind: item.ref.isJellyfin ? .jellyfin : .plex)
        serverTag.text = name
        serverTag.isHidden = false
        guard WaysToWatchLookup.offersWaysToWatch(item) else { return }
        serverRequest = ServerCopyCounts.request(item) { [weak self] others in
            guard let self, self.shownRef == item.ref, others > 0 else { return }
            self.serverTag.suffix = "+\(others)"
        }
    }
}

/// How many OTHER servers hold a title, read from its Ways to Watch lookup
/// (the same lookup and session cache the tile menu and detail page use).
///
/// Search asks for every result it shows, and each lookup is a detail read
/// plus a request per server, so at most `maxRunning` run at once; the newest
/// request starts first, since it is the result on screen now. A request whose
/// tile scrolled away is dropped before it starts.
@MainActor
enum ServerCopyCounts {
    final class Request {
        fileprivate let item: MediaItem
        fileprivate let done: (Int) -> Void
        fileprivate var observer: UUID?
        fileprivate var isCancelled = false

        fileprivate init(item: MediaItem, done: @escaping (Int) -> Void) {
            self.item = item
            self.done = done
        }

        /// A queued request is dropped; a running one keeps observing until its
        /// lookup finishes, so the slot it holds is released, and then reports
        /// nothing.
        func cancel() {
            isCancelled = true
            ServerCopyCounts.queue.removeAll { $0 === self }
        }
    }

    private static let maxRunning = 3
    private static var running = 0
    fileprivate static var queue: [Request] = []

    /// `done` gets the count once the lookup has finished; never, if the
    /// request is cancelled first.
    static func request(_ item: MediaItem, done: @escaping (Int) -> Void) -> Request {
        let request = Request(item: item, done: done)
        if let lookup = WaysToWatchLookup.existing(for: item) {
            // Cached or already running: no slot needed.
            attach(request, to: lookup, holdsSlot: false)
        } else {
            queue.append(request)
            pump()
        }
        return request
    }

    private static func pump() {
        while running < maxRunning, let next = queue.popLast() {
            running += 1
            attach(next, to: WaysToWatchLookup.lookup(for: next.item), holdsSlot: true)
        }
    }

    private static func attach(_ request: Request, to lookup: WaysToWatchLookup, holdsSlot: Bool) {
        var released = false
        func finish() {
            if holdsSlot, !released {
                released = true
                running -= 1
                pump()
            }
            if let observer = request.observer { lookup.stopObserving(observer) }
            request.observer = nil
            guard !request.isCancelled else { return }
            request.done(otherServers(in: lookup))
        }
        if lookup.isFinished {
            finish()
            return
        }
        request.observer = lookup.observe {
            guard lookup.isFinished else { return }
            finish()
        }
    }

    /// Servers other than the result's own with a copy of the title.
    private static func otherServers(in lookup: WaysToWatchLookup) -> Int {
        let own = lookup.ownCopy.machineId
        return Set(lookup.others.map(\.machineId)).subtracting([own]).count
    }
}

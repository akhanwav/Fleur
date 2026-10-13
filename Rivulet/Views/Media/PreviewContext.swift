// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewContext.swift
//  Rivulet
//
//  Shared state and preferences for the Apple TV-style row preview flow.
//

import SwiftUI

enum PreviewPhase: Equatable {
    case entryMorph
    case carouselStable
    case expandingHero
    case expandedHero
    case detailsStable
    case exiting
}

struct PreviewSourceTarget: Hashable {
    let rowID: String
    let itemID: String
}

enum PreviewBackAction: Equatable {
    case collapseToCarousel
    case dismissOverlay
}

struct PreviewStateMachine {
    private(set) var phase: PreviewPhase = .entryMorph
    private(set) var motionLocked = true

    var isCarouselInputEnabled: Bool {
        phase == .carouselStable
    }

    var isExpanded: Bool {
        // Includes the in-progress `.expandingHero` animation phase
        // because the user has already committed to expanding by the
        // time we reach it (`beginExpand()` transitioned out of
        // carousel-stable); the view is no longer carousel-interactive,
        // so semantically the preview is "expanded" from the user's
        // perspective for the duration of the animation.
        phase == .expandingHero || phase == .expandedHero || phase == .detailsStable
    }

    mutating func completeEntryMorph() {
        guard phase == .entryMorph else { return }
        phase = .carouselStable
    }

    mutating func beginPaging() {
        guard phase == .carouselStable else { return }
        motionLocked = true
    }

    mutating func finishPaging() {
        guard phase == .carouselStable else { return }
        motionLocked = false
    }

    mutating func beginExpand() {
        guard phase == .carouselStable || phase == .entryMorph else { return }
        phase = .expandingHero
        motionLocked = true
    }

    mutating func finishExpand() {
        guard phase == .expandingHero else { return }
        phase = .expandedHero
        motionLocked = false
    }

    mutating func markDetailsStable() {
        guard phase == .expandedHero || phase == .detailsStable else { return }
        phase = .detailsStable
    }

    /// Reverse of `markDetailsStable`: the user scrolled the below-fold back to
    /// the hero top. Returns to the expanded-hero rest state (still expanded,
    /// not collapsed to the carousel).
    mutating func returnToExpandedHero() {
        guard phase == .detailsStable else { return }
        phase = .expandedHero
        motionLocked = false
    }

    mutating func collapseToCarousel() {
        phase = .carouselStable
        motionLocked = false
    }

    mutating func setMotionLocked(_ locked: Bool) {
        motionLocked = locked
    }

    mutating func beginExit() {
        phase = .exiting
        motionLocked = true
    }

    mutating func exitAction(standaloneDetail: Bool = false) -> PreviewBackAction {
        switch phase {
        case .entryMorph, .carouselStable, .exiting:
            return .dismissOverlay
        case .expandingHero, .expandedHero, .detailsStable:
            // Standalone detail has no carousel to collapse back to — Back
            // dismisses the whole thing.
            if standaloneDetail { return .dismissOverlay }
            phase = .carouselStable
            motionLocked = false
            return .collapseToCarousel
        }
    }
}

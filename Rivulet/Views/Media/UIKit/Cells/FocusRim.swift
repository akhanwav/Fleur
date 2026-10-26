// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FocusRim.swift
//  Rivulet
//
//  Takes the light rim and the glare off a focused TVPosterView or
//  TVCardView, keeping the system's growth, motion and shadow.
//
//  On tvOS 26 a focused lockup draws its artwork through a Liquid Glass group
//  (a layer whose delegate is `_GlassGroupView`): a lensing layer that IS the
//  artwork, plus vibrant-colour, lighten (`plusL`) and darken (`plusD`)
//  passes over it. Those passes are the rim. Hiding the whole group hides the
//  artwork, so only the passes go, along with the specular glare layer.
//  Measured in the tvOS 26 simulator against screenshots of a focused poster
//  and card.
//
//  There is no public switch for any of this. Everything is matched by layer
//  class and filter name and only ever hidden, so on an OS that draws focus
//  differently nothing matches and nothing changes. The app's own glass
//  (a `UIVisualEffectView` inside a card) is never entered.
//

import UIKit

@MainActor
enum FocusRim {
    /// Hide the rim and glare inside `view` (a lockup, or a cell holding
    /// one). Call on every focus change: the system builds the glass on focus.
    static func remove(in view: UIView) {
        hideGlare(view.layer)
    }

    private static func hideGlare(_ layer: CALayer) {
        // Our own glass (badges, tags) is left alone.
        if layer.delegate is UIVisualEffectView { return }
        if NSStringFromClass(type(of: layer)).contains("SpecularHighlight") {
            layer.isHidden = true
            return
        }
        if isGlassGroup(layer) {
            hidePasses(layer)
            return
        }
        layer.sublayers?.forEach(hideGlare)
    }

    private static func hidePasses(_ layer: CALayer) {
        let blend = layer.compositingFilter as? String
        let vibrant = (layer.filters ?? []).contains { String(describing: $0).contains("vibrantColorMatrix") }
        if blend == "plusL" || blend == "plusD" || vibrant {
            layer.isHidden = true
            return
        }
        layer.sublayers?.forEach(hidePasses)
    }

    private static func isGlassGroup(_ layer: CALayer) -> Bool {
        guard let delegate = layer.delegate else { return false }
        return String(describing: type(of: delegate)) == "_GlassGroupView"
    }

    /// `remove(in:)` now and once the focus animation has run, for a cell's
    /// `didUpdateFocus`: the glass can be built either side of it.
    static func remove(in view: UIView, focused: Bool, coordinator: UIFocusAnimationCoordinator) {
        guard focused else { return }
        remove(in: view)
        coordinator.addCoordinatedAnimations(nil) { [weak view] in
            guard let view else { return }
            remove(in: view)
        }
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            remove(in: view)
        }
    }
}

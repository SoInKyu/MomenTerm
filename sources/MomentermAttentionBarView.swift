//
//  MomentermAttentionBarView.swift
//  iTerm2
//
//  Thin gradient strip pinned to the top edge of an individual split pane
//  (each SessionView owns one). PseudoTerminal's 1 Hz poller flips
//  `setActive(_:)` to YES on the strip belonging to a session that looks
//  like it's waiting for the user — specifically, output has been quiet
//  long enough AND the recent screen tail matches a known prompt UI
//  (typically Claude Code's `(y/N)`, numbered menu, or arrow selector).
//  While active, a soft left → right sweep continuously animates across
//  the strip; flipping back to NO stops the animation and hides the view.
//

import AppKit

@objc(MomentermAttentionBarView)
final class MomentermAttentionBarView: NSView {

    private var gradientLayer: CAGradientLayer {
        return layer as! CAGradientLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureGradient()
        isHidden = true
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    override func makeBackingLayer() -> CALayer {
        return CAGradientLayer()
    }

    override var isFlipped: Bool { true }

    /// Neon-cyan highlight color shared by the per-split strip drawn here and
    /// the per-tab strip drawn by PSMYosemiteTabStyle, so a single hue change
    /// propagates to both surfaces.
    @objc static var momentermAttentionHighlightColor: NSColor {
        return NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
    }

    private func configureGradient() {
        let g = gradientLayer
        g.startPoint = NSPoint(x: 0, y: 0.5)
        g.endPoint = NSPoint(x: 1, y: 0.5)
        // 5-stop gradient so the sweep has both a fade-in and a fade-out edge.
        // Colors stay constant; `locations` is what we animate to push the
        // bright stops from off-screen-left to off-screen-right.
        let neon = MomentermAttentionBarView.momentermAttentionHighlightColor
        g.colors = [
            NSColor.clear.cgColor,
            neon.withAlphaComponent(0.18).cgColor,
            neon.withAlphaComponent(0.85).cgColor,
            neon.withAlphaComponent(0.18).cgColor,
            NSColor.clear.cgColor,
        ]
        g.locations = [0.0, 0.2, 0.5, 0.8, 1.0]
    }

    /// Drives the visible state. Idempotent on the visibility axis (calling
    /// with the same `active` twice does not retoggle `isHidden`) but every
    /// `active == true` call verifies that the sweep animation is actually
    /// attached. macOS drops CAAnimations on occluded windows, metal toggles
    /// and layer regeneration, so without that re-check the strip stays
    /// visible but frozen — the poller would happily report active=true on
    /// every tick and the early-return would never recover the animation.
    @objc func setActive(_ active: Bool) {
        if active {
            if isHidden {
                isHidden = false
            }
            if gradientLayer.animation(forKey: "sweep") == nil {
                startSweepAnimation()
            }
        } else if !isHidden {
            gradientLayer.removeAnimation(forKey: "sweep")
            isHidden = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-attaching to a window can drop the layer's animation; restart
        // it if we're still meant to be visible.
        if !isHidden && gradientLayer.animation(forKey: "sweep") == nil {
            startSweepAnimation()
        }
    }

    private func startSweepAnimation() {
        let animation = CABasicAnimation(keyPath: "locations")
        // Start with the bright stops just off the left edge, end with them
        // just off the right edge, then loop. The negative→positive range
        // means the sweep "enters" from outside the view rather than
        // appearing mid-frame.
        animation.fromValue = [-0.6, -0.4, -0.1, 0.2, 0.4] as [NSNumber]
        animation.toValue = [0.6, 0.8, 1.1, 1.4, 1.6] as [NSNumber]
        animation.duration = 1.6
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(animation, forKey: "sweep")
    }
}

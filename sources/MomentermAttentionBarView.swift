//
//  MomentermAttentionBarView.swift
//  iTerm2
//
//  Thin gradient strip pinned to the top edge of the terminal content area.
//  PseudoTerminal flips `setActive(_:)` to YES when a non-foreground tab in
//  the window receives new output (`PTYSession.newOutput`) so the user can
//  spot at a glance that another tab is waiting on them — typically a
//  Claude prompt asking for confirmation. While active, a soft left → right
//  sweep continuously animates across the strip; flipping back to NO stops
//  the animation and hides the view.
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

    private func configureGradient() {
        let g = gradientLayer
        g.startPoint = NSPoint(x: 0, y: 0.5)
        g.endPoint = NSPoint(x: 1, y: 0.5)
        // 5-stop gradient so the sweep has both a fade-in and a fade-out edge.
        // Colors stay constant; `locations` is what we animate to push the
        // bright stops from off-screen-left to off-screen-right.
        g.colors = [
            NSColor.clear.cgColor,
            NSColor.systemBlue.withAlphaComponent(0.18).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.85).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.18).cgColor,
            NSColor.clear.cgColor,
        ]
        g.locations = [0.0, 0.2, 0.5, 0.8, 1.0]
    }

    /// Drives the visible state. Calling with the same value twice is a
    /// no-op so we never re-add the animation while it's already running.
    @objc func setActive(_ active: Bool) {
        if active == !isHidden {
            return
        }
        if active {
            isHidden = false
            startSweepAnimation()
        } else {
            gradientLayer.removeAnimation(forKey: "sweep")
            isHidden = true
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

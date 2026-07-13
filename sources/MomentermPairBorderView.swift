//
//  MomentermPairBorderView.swift
//  iTerm2
//
//  Non-interactive overlay that visually groups the two panes taking part in
//  an AI pairing session. Each paired SessionView gets one of these on top:
//
//    • a persistent neon border (shared hue with MomentermAttentionBarView) so
//      the two panes read as one group, and
//    • a top-left pill naming the pane's role (편집자 / 검토자) plus whose turn
//      it is — the active speaker's border brightens and its pill pulses, so
//      the direction of the exchange is visible at a glance.
//
//  On completion the border switches to a solid outcome color and the pill
//  shows the result (승인/상한/정지). Clicks pass straight through to the
//  terminal (hitTest returns nil).
//

import AppKit

@objc(MomentermPairBorderView)
final class MomentermPairBorderView: NSView {

    private let role: MomentermPairRole
    private let pill = NSTextField(labelWithString: "")
    private let pillBackground = NSView()
    private var isActive = false
    private var completed = false

    private var neon: NSColor { MomentermAttentionBarView.momentermAttentionHighlightColor }

    @objc init(role: MomentermPairRole) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 2.5
        layer?.cornerRadius = 3
        layer?.borderColor = neon.withAlphaComponent(0.35).cgColor

        pillBackground.wantsLayer = true
        pillBackground.layer?.cornerRadius = 4
        pillBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        addSubview(pillBackground)

        pill.font = .systemFont(ofSize: 11, weight: .semibold)
        pill.textColor = neon
        pill.backgroundColor = .clear
        pill.isBezeled = false
        pill.isEditable = false
        pill.drawsBackground = false
        addSubview(pill)

        updatePillText()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    override var isFlipped: Bool { true }

    // Pass all mouse events through to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    /// Attach to a session's view, filling it and tracking resizes.
    @objc func attach(to host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        layoutPill()
    }

    @objc func detach() {
        removeFromSuperview()
    }

    override func layout() {
        super.layout()
        layoutPill()
    }

    private func layoutPill() {
        pill.sizeToFit()
        let padX: CGFloat = 8
        let padY: CGFloat = 3
        let w = pill.frame.width + padX * 2
        let h = pill.frame.height + padY * 2
        let x: CGFloat = 8
        let y: CGFloat = 8
        pillBackground.frame = NSRect(x: x, y: y, width: w, height: h)
        pill.frame = NSRect(x: x + padX, y: y + padY, width: pill.frame.width, height: pill.frame.height)
    }

    private var roleName: String {
        switch role {
        case .editor: return "편집자 (Claude)"
        case .reviewer: return "검토자 (Codex)"
        }
    }

    private func updatePillText() {
        if completed { return }
        pill.stringValue = isActive ? "● \(roleName) · 진행 중" : "\(roleName) · 대기"
        pill.textColor = isActive ? neon : neon.withAlphaComponent(0.6)
        layoutPill()
    }

    /// Brighten + pulse when this pane is the current speaker; dim otherwise.
    @objc func setActive(_ active: Bool) {
        guard !completed else { return }
        isActive = active
        updatePillText()
        layer?.removeAnimation(forKey: "pulse")
        if active {
            layer?.borderColor = neon.cgColor
            let pulse = CABasicAnimation(keyPath: "borderColor")
            pulse.fromValue = neon.withAlphaComponent(1.0).cgColor
            pulse.toValue = neon.withAlphaComponent(0.35).cgColor
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "pulse")
        } else {
            layer?.borderColor = neon.withAlphaComponent(0.35).cgColor
        }
    }

    /// Terminal state: solid outcome color, no pulse, result in the pill.
    @objc func showCompletion(text: String, color: NSColor) {
        completed = true
        isActive = false
        layer?.removeAnimation(forKey: "pulse")
        layer?.borderColor = color.cgColor
        pill.stringValue = "\(roleName) · \(text)"
        pill.textColor = color
        layoutPill()
    }
}

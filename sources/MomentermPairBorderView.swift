//
//  MomentermPairBorderView.swift
//  iTerm2
//
//  Non-interactive overlay that visually groups the two panes taking part in
//  an AI pairing session. Each paired SessionView gets one of these on top:
//
//    • a persistent neon border in the PAIR's own accent color — every pair
//      draws from a small palette by ordinal, so when several pairs coexist,
//      matching colors (and the matching ① ② badges in the pills) say which
//      editor belongs to which reviewer at a glance, and
//    • a top-left pill naming the pane's role (① 편집자 / ① 검토자) plus whose
//      turn it is — the active speaker's border brightens and its pill pulses,
//      so the direction of the exchange is visible at a glance.
//
//  On completion the border switches to a solid outcome color and the pill
//  shows the result (승인/상한/정지). Clicks pass straight through to the
//  terminal (hitTest returns nil).
//

import AppKit

@objc(MomentermPairBorderView)
final class MomentermPairBorderView: NSView {

    private let role: MomentermPairRole
    private let ordinal: Int
    private let pill = NSTextField(labelWithString: "")
    private let pillBackground = NSView()
    private var isActive = false
    private var completed = false
    /// Non-terminating notice appended to the pill (e.g. stalled turn
    /// detection). Cleared on every new turn; never survives completion.
    private var advisory: String?

    /// The pair's accent color; both panes of a pair share it.
    private let neon: NSColor

    /// Per-pair accent palette, cycled by pair ordinal. Hues are chosen to
    /// stay distinct from the completion-banner colors (green/orange/red).
    private static let accentPalette: [NSColor] = [
        MomentermAttentionBarView.momentermAttentionHighlightColor,  // 네온 시안
        .systemPink,
        .systemYellow,
        .systemPurple,
    ]

    @objc static func accentColor(forOrdinal ordinal: Int) -> NSColor {
        return accentPalette[max(0, ordinal - 1) % accentPalette.count]
    }

    @objc init(role: MomentermPairRole, accent: NSColor, ordinal: Int) {
        self.role = role
        self.neon = accent
        self.ordinal = ordinal
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

    /// Attach to a session's view, filling it and tracking resizes. While the
    /// relay is live (from attach until completion or detach), the pane is
    /// exempt from inactive-pane dimming so both halves of the pair stay at
    /// full brightness.
    ///
    /// SessionView lays its subviews out manually, so an autoresizing mask
    /// alone does not keep this overlay glued to the pane through splitter
    /// drags and window resizes — track the host's frame notifications too.
    @objc func attach(to host: NSView) {
        frame = host.bounds
        autoresizingMask = [.width, .height]
        host.addSubview(self)
        (host as? SessionView)?.momentermPairUndimmed = true
        host.postsFrameChangedNotifications = true
        hostFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: host,
            queue: .main) { [weak self, weak host] _ in
            guard let self, let host, self.superview === host else { return }
            self.frame = host.bounds
            self.layoutPill()
        }
        layoutPill()
    }

    @objc func detach() {
        removeHostFrameObserver()
        (superview as? SessionView)?.momentermPairUndimmed = false
        removeFromSuperview()
    }

    private var hostFrameObserver: NSObjectProtocol?

    private func removeHostFrameObserver() {
        if let token = hostFrameObserver {
            NotificationCenter.default.removeObserver(token)
            hostFrameObserver = nil
        }
    }

    deinit {
        removeHostFrameObserver()
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
        // Sit below the pane's per-pane title bar when one is shown — the
        // pill must label the pane, not cover its title.
        var y: CGFloat = 8
        if let host = superview as? SessionView, host.showTitle() {
            y = SessionView.titleHeight() + 6
        }
        pillBackground.frame = NSRect(x: x, y: y, width: w, height: h)
        pill.frame = NSRect(x: x + padX, y: y + padY, width: pill.frame.width, height: pill.frame.height)
    }

    private var roleName: String {
        let badge = Self.badge(forOrdinal: ordinal)
        switch role {
        case .editor: return "\(badge) 편집자 (Claude)"
        case .reviewer: return "\(badge) 검토자 (Codex)"
        }
    }

    /// ①②③… badge shared by both pills of a pair. Falls back to “#n” past ⑳.
    private static func badge(forOrdinal ordinal: Int) -> String {
        if (1...20).contains(ordinal), let scalar = UnicodeScalar(0x245F + ordinal) {
            return String(scalar)
        }
        return "#\(ordinal)"
    }

    private func updatePillText() {
        if completed { return }
        var text = isActive ? "● \(roleName) · 진행 중" : "\(roleName) · 대기"
        var color = isActive ? neon : neon.withAlphaComponent(0.6)
        if let advisory {
            text += " · ⚠ \(advisory)"
            color = .systemOrange
        }
        pill.stringValue = text
        pill.textColor = color
        layoutPill()
    }

    /// Show a non-terminating notice in the pill (the relay keeps running).
    @objc func showAdvisory(_ text: String) {
        guard !completed, advisory != text else { return }
        advisory = text
        updatePillText()
    }

    @objc func clearAdvisory() {
        guard advisory != nil else { return }
        advisory = nil
        updatePillText()
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
    /// The pair is over, so the pane goes back to normal dimming rules — the
    /// full-brightness override only applies while the relay is live.
    @objc func showCompletion(text: String, color: NSColor) {
        completed = true
        isActive = false
        (superview as? SessionView)?.momentermPairUndimmed = false
        layer?.removeAnimation(forKey: "pulse")
        layer?.borderColor = color.cgColor
        pill.stringValue = "\(roleName) · \(text)"
        pill.textColor = color
        layoutPill()
    }
}

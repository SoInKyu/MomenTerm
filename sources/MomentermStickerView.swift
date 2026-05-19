//
//  MomentermStickerView.swift
//  iTerm2
//
//  Rounded-pill text label pinned to the top edge of a split pane. Each
//  SessionView owns one, lazily created in -updateMomentermStickerFrame
//  alongside the attention strip. The text comes from PTYSession's
//  `momentermSessionSticker` property, which is persisted in the session
//  arrangement so the label survives window restoration and app relaunch.
//
//  Stays out of the terminal user's way:
//    * `isHidden` flips to true whenever the text is empty
//    * `hitTest(_:)` returns nil so right-clicks / text-selection on the
//      pill fall through to the PTYTextView underneath — the right-click
//      menu (with "스티커 편집…" / "스티커 제거") remains the single editing
//      path, no separate hover/click affordance to learn.
//

import AppKit

@objc(MomentermStickerView)
final class MomentermStickerView: NSView {

    private var text: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    override var isFlipped: Bool { true }

    /// Reserved vertical space for the pill, including a small breathing
    /// margin above and below. SessionView uses this to size the strip
    /// frame; the pill itself draws shorter than the strip so the rounded
    /// edges feel grounded rather than touching the title-bar/scrollview
    /// boundary.
    @objc static let preferredHeight: CGFloat = 22

    /// Bridge for ObjC callers (PTYSession setter, SessionView lazy-init).
    /// nil / empty hides the view entirely so a sessions without a sticker
    /// cost zero pixels and zero drawing work.
    @objc func setText(_ newText: String?) {
        let normalized = (newText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == text { return }
        text = normalized
        isHidden = normalized.isEmpty
        needsDisplay = true
    }

    @objc var currentText: String { text }

    /// Mouse and right-click events pass straight through to the PTYTextView
    /// underneath. The right-click menu on the textview is where stickers
    /// are edited / removed, so the pill itself never needs to intercept
    /// clicks. This also means selection / drag-to-select keeps working in
    /// the top row of terminal content even when the pill overlaps it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDarkAppearance: Bool {
        if let match = effectiveAppearance.bestMatch(from: [.aqua,
                                                            .darkAqua,
                                                            .vibrantLight,
                                                            .vibrantDark]) {
            return match == .darkAqua || match == .vibrantDark
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, bounds.width > 8 else { return }

        let dark = isDarkAppearance
        let pillFill: NSColor
        let textColor: NSColor
        let strokeColor: NSColor
        if dark {
            pillFill = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
            textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
            strokeColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
        } else {
            pillFill = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
            textColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
            strokeColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
        }

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]

        let display = "📌  \(text)" as NSString
        let measured = display.size(withAttributes: attrs)
        let horizontalPadding: CGFloat = 8
        let pillHeight: CGFloat = 18
        let verticalInset = max((bounds.height - pillHeight) / 2, 0)
        let pillMaxWidth = max(bounds.width - 8, 0)
        let pillWidth = min(measured.width + horizontalPadding * 2, pillMaxWidth)

        // Right-aligned pill: anchor to the trailing edge so it sits in
        // the split's top-right corner. textRect below picks up the new
        // minX automatically.
        let trailingMargin: CGFloat = 4
        let pillRect = NSRect(x: max(bounds.width - pillWidth - trailingMargin, 4),
                              y: verticalInset,
                              width: pillWidth,
                              height: pillHeight)

        let path = NSBezierPath(roundedRect: pillRect, xRadius: 5, yRadius: 5)
        pillFill.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let textRect = NSRect(x: pillRect.minX + horizontalPadding,
                              y: pillRect.minY + (pillRect.height - measured.height) / 2,
                              width: max(pillRect.width - horizontalPadding * 2, 0),
                              height: measured.height)
        display.draw(in: textRect, withAttributes: attrs)
    }
}

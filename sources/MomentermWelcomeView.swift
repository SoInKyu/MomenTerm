//
//  MomentermWelcomeView.swift
//  iTerm2
//
//  Created by MomenTerm on 2026-05-14.
//  Right-pane content shown by MomentermWelcomeWindowController when no
//  project has been selected yet. No PTY, no shell — just the app icon
//  and a four-line guidance message.
//

import AppKit

@objc final class MomentermWelcomeView: NSView {

    private let iconView = NSImageView()
    private let conceptLine1 = NSTextField(labelWithString: "MomenTerm은 프로젝트 단위로")
    private let conceptLine2 = NSTextField(labelWithString: "동작하는 터미널입니다.")
    private let guideLine1   = NSTextField(labelWithString: "좌측에서 폴더나 Git 저장소를")
    private let guideLine2   = NSTextField(labelWithString: "선택하면 작업이 시작됩니다.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        for label in [conceptLine1, conceptLine2, guideLine1, guideLine2] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 13)
            label.alignment = .center
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        let w = bounds.width
        let h = bounds.height
        let iconSize: CGFloat = 64
        let lineH: CGFloat = 20
        let gapIconText: CGFloat = 20
        let gapConceptGuide: CGFloat = 14

        let totalH = iconSize + gapIconText + lineH * 2 + gapConceptGuide + lineH * 2
        var y = max(0, (h - totalH) / 2.0)

        iconView.frame = NSRect(x: (w - iconSize) / 2.0, y: y, width: iconSize, height: iconSize)
        y += iconSize + gapIconText

        conceptLine1.frame = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH
        conceptLine2.frame = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH + gapConceptGuide
        guideLine1.frame   = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH
        guideLine2.frame   = NSRect(x: 0, y: y, width: w, height: lineH)
    }
}

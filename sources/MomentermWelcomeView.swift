//
//  MomentermWelcomeView.swift
//  iTerm2
//
//  Created by MomenTerm on 2026-05-14.
//  Right-pane content shown by MomentermWelcomeWindowController when no
//  project has been selected yet. App icon, four-line guidance, and a
//  status card that lets the user promote the bundled Symbols Nerd Font
//  to system-wide install (~/Library/Fonts/) so other apps see it too.
//

import AppKit

@objc final class MomentermWelcomeView: NSView {

    private let iconView = NSImageView()
    private let conceptLine1 = NSTextField(labelWithString: "MomenTerm은 프로젝트 단위로")
    private let conceptLine2 = NSTextField(labelWithString: "동작하는 터미널입니다.")
    private let guideLine1   = NSTextField(labelWithString: "좌측에서 폴더나 Git 저장소를")
    private let guideLine2   = NSTextField(labelWithString: "선택하면 작업이 시작됩니다.")

    private let card = NSBox()
    private let cardStatusLabel = NSTextField(labelWithString: "")
    private let cardActionButton = NSButton(title: "", target: nil, action: nil)

    // Bundled font that gets registered .process-scope at launch. The
    // card lets users promote the same file to .persistent (system-wide).
    private static let bundledFontFileName = "SymbolsNerdFont-Regular.ttf"

    private static var systemFontDestURL: URL {
        URL(fileURLWithPath: FileManager.default.fontsDirectory())
            .appendingPathComponent(bundledFontFileName)
    }

    private static func isFontInstalledSystemWide() -> Bool {
        FileManager.default.fileExists(atPath: systemFontDestURL.path)
    }

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

        setUpCard()
        addSubview(card)
        refreshCardState()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    private func setUpCard() {
        card.boxType = .custom
        card.borderColor = NSColor.separatorColor
        card.borderWidth = 1
        card.cornerRadius = 8
        card.fillColor = NSColor.controlBackgroundColor
        card.titlePosition = .noTitle
        card.contentViewMargins = NSSize(width: 12, height: 10)

        cardStatusLabel.textColor = .labelColor
        cardStatusLabel.font = .systemFont(ofSize: 12)
        cardStatusLabel.alignment = .left
        cardStatusLabel.lineBreakMode = .byTruncatingTail
        cardStatusLabel.maximumNumberOfLines = 1

        cardActionButton.bezelStyle = .rounded
        cardActionButton.controlSize = .small
        cardActionButton.font = .systemFont(ofSize: 11)
        cardActionButton.target = self
        cardActionButton.action = #selector(installSystemWide(_:))

        let content = NSView(frame: .zero)
        content.addSubview(cardStatusLabel)
        content.addSubview(cardActionButton)
        card.contentView = content
    }

    private func refreshCardState() {
        if Self.isFontInstalledSystemWide() {
            cardStatusLabel.stringValue = "Nerd 글리프 폰트가 시스템에 설치되어 있습니다."
            cardActionButton.title = "✓ 설치 완료"
            cardActionButton.isEnabled = false
        } else {
            cardStatusLabel.stringValue = "MomenTerm 안에서는 바로 사용할 수 있어요."
            cardActionButton.title = "다른 앱에서도 사용"
            cardActionButton.isEnabled = true
        }
        needsLayout = true
    }

    @objc private func installSystemWide(_ sender: NSButton) {
        cardActionButton.isEnabled = false
        cardActionButton.title = "설치 중…"
        NerdFontInstaller.installBundledFontsToSystem(window: window) { [weak self] error in
            guard let self else { return }
            if let error {
                self.cardActionButton.isEnabled = true
                self.cardActionButton.title = "다시 시도"
                iTermWarning.show(withTitle: "폰트를 시스템에 설치하지 못했습니다: \(error.localizedDescription)",
                                  actions: ["확인"],
                                  accessory: nil,
                                  identifier: "MomentermBundledFontInstallFailed",
                                  silenceable: .kiTermWarningTypeTemporarilySilenceable,
                                  heading: "설치 실패",
                                  window: self.window)
                return
            }
            self.refreshCardState()
        }
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
        let gapGuideCard: CGFloat = 24
        let cardW: CGFloat = min(w - 32, 360)
        let cardH: CGFloat = 56

        let totalH = iconSize + gapIconText + lineH * 2 + gapConceptGuide + lineH * 2 + gapGuideCard + cardH
        var y = max(0, (h - totalH) / 2.0)

        iconView.frame = NSRect(x: (w - iconSize) / 2.0, y: y, width: iconSize, height: iconSize)
        y += iconSize + gapIconText

        conceptLine1.frame = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH
        conceptLine2.frame = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH + gapConceptGuide
        guideLine1.frame   = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH
        guideLine2.frame   = NSRect(x: 0, y: y, width: w, height: lineH); y += lineH + gapGuideCard

        card.frame = NSRect(x: (w - cardW) / 2.0, y: y, width: cardW, height: cardH)

        // Card content is bottom-up coords (NSBox.contentView isn't flipped).
        let content = card.contentView!
        let contentBounds = content.bounds
        let buttonSize = cardActionButton.intrinsicContentSize
        let buttonW = max(buttonSize.width + 12, 96)
        let buttonH = max(buttonSize.height, 22)
        let buttonX = contentBounds.width - buttonW
        let buttonY = (contentBounds.height - buttonH) / 2.0
        cardActionButton.frame = NSRect(x: buttonX, y: buttonY, width: buttonW, height: buttonH)

        let labelW = max(0, buttonX - 8)
        let labelH = cardStatusLabel.intrinsicContentSize.height
        let labelY = (contentBounds.height - labelH) / 2.0
        cardStatusLabel.frame = NSRect(x: 0, y: labelY, width: labelW, height: labelH)
    }
}

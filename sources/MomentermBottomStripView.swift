//
//  MomentermBottomStripView.swift
//  iTerm2
//
//  Slim bar pinned to the very bottom of the terminal window. Hosts the
//  toggle entries for the inline panels (Git Graph, Browser) on the left,
//  the current bundle version centred (clickable to trigger a manual
//  update check), and is sized to match the terminal-window content. Uses
//  frame + autoresizingMask so the strip respects the project rule against
//  auto layout in the terminal window.
//

import AppKit

@objc(MomentermBottomStripDelegate)
protocol MomentermBottomStripDelegate: AnyObject {
    func momentermBottomStripDidTapGitGraph()
    func momentermBottomStripDidTapBrowser()
    @objc optional func momentermBottomStripDidTapVersion()
    @objc optional func momentermBottomStripDidTapSettings(from anchor: NSView)
    @objc optional func momentermBottomStripDidTapClaude()
}

@objc(MomentermBottomStripStatus)
enum MomentermBottomStripStatus: Int {
    case idle
    case checking
    case noUpdate
    case updateReady
}

@objc(MomentermBottomStripView)
final class MomentermBottomStripView: NSView {

    /// Posted by `iTermApplicationDelegate` whenever Sparkle moves into a
    /// state worth surfacing on the version label. `userInfo["status"]` is
    /// the raw value of `MomentermBottomStripStatus`. Every live strip
    /// observes this and updates itself.
    @objc static let versionStatusNotification = Notification.Name("MomentermBottomStripVersionStatusDidChange")
    @objc static let versionStatusUserInfoKey = "status"

    /// Renders the GitHub git-branch octicon (3 dots in an "h" arrangement
    /// — top-left + bottom-left + top-right, joined by a stem and a curve)
    /// as a template NSImage. Used in both the title-bar accessory and the
    /// bottom strip so the Git Graph affordance reads identically. The
    /// SF Symbol `arrow.triangle.branch` is the closest stock alternative
    /// but lacks the canonical 2-on-stem + 1-branched layout that users
    /// instantly recognise as "git".
    @objc(gitBranchIconWithSide:)
    static func gitBranchIcon(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side),
                            flipped: true) { rect in
            let s = rect.width / 16.0   // SVG viewBox is 16×16
            let lineWidth: CGFloat = 1.6 * s
            let color = NSColor.labelColor
            color.setStroke()
            color.setFill()

            let stem = NSBezierPath()
            stem.lineWidth = lineWidth
            stem.lineCapStyle = .round
            stem.move(to: NSPoint(x: 4.25 * s, y: 4.75 * s))
            stem.line(to: NSPoint(x: 4.25 * s, y: 11.25 * s))
            stem.stroke()

            let branch = NSBezierPath()
            branch.lineWidth = lineWidth
            branch.lineCapStyle = .round
            branch.move(to: NSPoint(x: 4.25 * s, y: 7.0 * s))
            branch.curve(to: NSPoint(x: 11.75 * s, y: 4.75 * s),
                         controlPoint1: NSPoint(x: 11.75 * s, y: 7.0 * s),
                         controlPoint2: NSPoint(x: 11.75 * s, y: 5.6 * s))
            branch.stroke()

            for (cx, cy) in [(4.25, 3.25), (4.25, 12.75), (11.75, 3.25)] {
                let dot = NSBezierPath(ovalIn: NSRect(x: (CGFloat(cx) - 1.5) * s,
                                                        y: (CGFloat(cy) - 1.5) * s,
                                                        width: 3.0 * s,
                                                        height: 3.0 * s))
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc weak var delegate: MomentermBottomStripDelegate?

    private let topLine = NSView()
    private let graphButton = NSButton()
    private let browserButton = NSButton()
    private let versionButton = NSButton()
    // Right-side icon group (always shown — these are the affordances that
    // used to live in the title-bar accessory but were invisible on compact
    // windows, so they relocated here).
    private let gearButton = NSButton()
    private let gearClaudeSeparator = NSBox()
    private let claudeButton = NSButton()
    private let gitGraphIconButton = NSButton()
    private let showsToolButtons: Bool
    private let baseVersionText: String
    private var revertWorkItem: DispatchWorkItem?

    @objc override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, showsToolButtons: true)
    }

    @objc init(frame frameRect: NSRect, showsToolButtons: Bool) {
        self.showsToolButtons = showsToolButtons
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        baseVersionText = short.isEmpty ? "MomenTerm" : "v\(short)"
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        addSubview(topLine)

        if showsToolButtons {
            configure(button: graphButton,
                      symbolName: "arrow.triangle.branch",
                      title: "Git Graph",
                      selector: #selector(graphTapped))
            graphButton.image = MomentermBottomStripView.gitBranchIcon(side: 14)
            configure(button: browserButton,
                      symbolName: "globe",
                      title: "Browser",
                      selector: #selector(browserTapped))
            addSubview(graphButton)
            addSubview(browserButton)
        }

        configureVersionButton()
        addSubview(versionButton)

        configureRightIconGroup()

        layoutContents()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleVersionStatusNotification(_:)),
                                               name: MomentermBottomStripView.versionStatusNotification,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    @objc private func handleVersionStatusNotification(_ note: Notification) {
        guard let raw = note.userInfo?[MomentermBottomStripView.versionStatusUserInfoKey] as? Int,
              let status = MomentermBottomStripStatus(rawValue: raw) else { return }
        setVersionStatus(status)
    }

    private func configure(button: NSButton, symbolName: String, title: String, selector: Selector) {
        let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.image = symbolImage?.withSymbolConfiguration(symbolConfig)
        button.title = title
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = self
        button.action = selector
        button.toolTip = title
        button.alignment = .left
    }

    private func configureRightIconGroup() {
        configureSymbolIconButton(gearButton,
                                  symbol: "gearshape",
                                  title: "설정",
                                  selector: #selector(gearIconTapped))
        addSubview(gearButton)

        gearClaudeSeparator.boxType = .separator
        addSubview(gearClaudeSeparator)

        claudeButton.isBordered = false
        claudeButton.imagePosition = .imageOnly
        claudeButton.imageScaling = .scaleProportionallyDown
        if let original = NSImage(named: "ai-claude-code"),
           let copy = original.copy() as? NSImage {
            copy.size = NSSize(width: 14, height: 14)
            claudeButton.image = copy
        }
        claudeButton.toolTip = "현재 프로젝트에서 Claude 실행"
        claudeButton.target = self
        claudeButton.action = #selector(claudeIconTapped)
        addSubview(claudeButton)

        gitGraphIconButton.isBordered = false
        gitGraphIconButton.imagePosition = .imageOnly
        gitGraphIconButton.imageScaling = .scaleProportionallyDown
        gitGraphIconButton.image = MomentermBottomStripView.gitBranchIcon(side: 14)
        gitGraphIconButton.toolTip = "Git Graph"
        gitGraphIconButton.target = self
        gitGraphIconButton.action = #selector(graphTapped)
        addSubview(gitGraphIconButton)
    }

    private func configureSymbolIconButton(_ button: NSButton,
                                           symbol: String,
                                           title: String,
                                           selector: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.target = self
        button.action = selector
    }

    private func configureVersionButton() {
        versionButton.title = baseVersionText
        versionButton.font = .systemFont(ofSize: 11, weight: .medium)
        versionButton.contentTintColor = .tertiaryLabelColor
        versionButton.isBordered = false
        versionButton.bezelStyle = .regularSquare
        versionButton.target = self
        versionButton.action = #selector(versionTapped)
        versionButton.toolTip = "클릭하여 업데이트 확인"
        versionButton.alignment = .center
        versionButton.setButtonType(.momentaryChange)
    }

    override func layout() {
        super.layout()
        layoutContents()
    }

    private func layoutContents() {
        let h = bounds.height
        let w = bounds.width
        topLine.frame = NSRect(x: 0, y: h - 0.5, width: w, height: 0.5)
        let buttonH: CGFloat = h - 8
        let buttonY: CGFloat = 4

        if showsToolButtons {
            let leftMargin: CGFloat = 10
            let gap: CGFloat = 12
            let graphSize = graphButton.intrinsicContentSize
            let browserSize = browserButton.intrinsicContentSize
            let graphW = max(72, graphSize.width + 8)
            let browserW = max(72, browserSize.width + 8)
            graphButton.frame = NSRect(x: leftMargin, y: buttonY, width: graphW, height: buttonH)
            browserButton.frame = NSRect(x: leftMargin + graphW + gap, y: buttonY, width: browserW, height: buttonH)
        }

        let versionW: CGFloat = max(160, versionButton.intrinsicContentSize.width + 16)
        let versionX = (w - versionW) / 2.0
        versionButton.frame = NSRect(x: versionX, y: buttonY, width: versionW, height: buttonH)

        // Right-side icon group, packed from the right edge inward:
        // [gear] | [claude] [git-branch]   ← right-anchored
        let iconSize: CGFloat = 22
        let iconGap: CGFloat = 4
        let rightMargin: CGFloat = 10
        let sepW: CGFloat = 1
        let sepH: CGFloat = 14
        let iconY = (h - iconSize) / 2.0
        let sepY = (h - sepH) / 2.0

        var rx = w - rightMargin - iconSize
        gitGraphIconButton.frame = NSRect(x: rx, y: iconY, width: iconSize, height: iconSize)
        rx -= iconSize + iconGap
        claudeButton.frame = NSRect(x: rx, y: iconY, width: iconSize, height: iconSize)
        rx -= sepW + iconGap
        gearClaudeSeparator.frame = NSRect(x: rx, y: sepY, width: sepW, height: sepH)
        rx -= iconSize + iconGap
        gearButton.frame = NSRect(x: rx, y: iconY, width: iconSize, height: iconSize)
    }

    /// Mark which inline panel is currently visible so the button shows an
    /// "on" tint. Pass an empty string to clear both.
    @objc func setActivePanel(_ panel: String) {
        guard showsToolButtons else { return }
        graphButton.contentTintColor = (panel == "gitgraph") ? .controlAccentColor : .secondaryLabelColor
        browserButton.contentTintColor = (panel == "browser") ? .controlAccentColor : .secondaryLabelColor
    }

    /// Drive the version label's transient text. `.idle` shows the bundle
    /// version, the other states display short Korean affordances and
    /// auto-revert to `.idle` after a few seconds (except `.updateReady`,
    /// which stays pinned until the app relaunches).
    @objc func setVersionStatus(_ status: MomentermBottomStripStatus) {
        revertWorkItem?.cancel()
        switch status {
        case .idle:
            versionButton.title = baseVersionText
            versionButton.contentTintColor = .tertiaryLabelColor
        case .checking:
            versionButton.title = "업데이트 확인 중…"
            versionButton.contentTintColor = .secondaryLabelColor
            scheduleRevert(after: 6)
        case .noUpdate:
            versionButton.title = "이미 최신 버전입니다 — \(baseVersionText)"
            versionButton.contentTintColor = .secondaryLabelColor
            scheduleRevert(after: 4)
        case .updateReady:
            versionButton.title = "MomenTerm을 재시작하면 최신 버전으로 적용됩니다."
            versionButton.contentTintColor = .controlAccentColor
        }
        needsLayout = true
    }

    private func scheduleRevert(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.setVersionStatus(.idle)
        }
        revertWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func graphTapped() { delegate?.momentermBottomStripDidTapGitGraph() }
    @objc private func browserTapped() { delegate?.momentermBottomStripDidTapBrowser() }
    @objc private func versionTapped() { delegate?.momentermBottomStripDidTapVersion?() }
    @objc private func gearIconTapped() {
        delegate?.momentermBottomStripDidTapSettings?(from: gearButton)
    }
    @objc private func claudeIconTapped() {
        delegate?.momentermBottomStripDidTapClaude?()
    }
}

//
//  MomentermTitlebarAccessoryVC.swift
//  iTerm2
//
//  Holds the four-item title-bar accessory pinned to the leading edge of
//  every MomenTerm window (Welcome + Terminal): [⚙ 환경설정 | ✨ Claude
//  ⎇ Git Graph]. The gear and Claude buttons route into the embedded
//  sidebar VC; Git Graph forwards to a host-provided delegate so the
//  Welcome window (which has no live terminal) and the terminal window
//  can wire the action differently.
//

import AppKit

@objc(MomentermTitlebarAccessoryDelegate)
protocol MomentermTitlebarAccessoryDelegate: AnyObject {
    func momentermTitlebarAccessoryDidTapGitGraph()
}

@objc(MomentermTitlebarAccessoryVC)
final class MomentermTitlebarAccessoryVC: NSTitlebarAccessoryViewController {

    @objc weak var sidebarVC: MomentermEmbeddedSidebarVC?
    @objc weak var actionDelegate: MomentermTitlebarAccessoryDelegate?

    private let gearButton = NSButton()
    private let claudeButton = NSButton()
    private let gitGraphButton = NSButton()
    private let separator = NSBox()

    @objc init() {
        super.init(nibName: nil, bundle: nil)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 28))

        configureSymbolButton(gearButton,
                              symbol: "gearshape",
                              title: "설정",
                              selector: #selector(gearTapped))
        host.addSubview(gearButton)

        separator.boxType = .separator
        host.addSubview(separator)

        configureClaudeButton(claudeButton, selector: #selector(claudeTapped))
        host.addSubview(claudeButton)

        configureSymbolButton(gitGraphButton,
                              symbol: "arrow.triangle.branch",
                              title: "Git Graph",
                              selector: #selector(gitGraphTapped))
        // Override the SF Symbol fallback with the GitHub-style git-branch
        // octicon so both title-bar and bottom-strip read the same shape.
        gitGraphButton.image = MomentermBottomStripView.gitBranchIcon(side: 14)
        gitGraphButton.contentTintColor = .secondaryLabelColor
        host.addSubview(gitGraphButton)

        layoutChildren(in: host)
        view = host
        // Trailing edge so the sidebar-toggle button stays anchored next to
        // the traffic lights on the leading side without competing for the
        // same slot.
        layoutAttribute = .trailing
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    private func configureSymbolButton(_ button: NSButton,
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

    private func configureClaudeButton(_ button: NSButton, selector: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        // Constrain the brand asset's logical size to roughly match the SF
        // Symbol pointSize used by the other title-bar buttons so all three
        // icons read at the same visual weight. Copy first so the size
        // mutation does not leak into the shared NSImage(named:) cache.
        if let original = NSImage(named: "ai-claude-code"),
           let copy = original.copy() as? NSImage {
            copy.size = NSSize(width: 14, height: 14)
            button.image = copy
        }
        button.toolTip = "현재 프로젝트에서 Claude 실행"
        button.target = self
        button.action = selector
    }

    private func layoutChildren(in host: NSView) {
        let size: CGFloat = 22
        let pad: CGFloat = 4
        let y: CGFloat = (host.bounds.height - size) / 2.0
        let sepH: CGFloat = 16
        let sepY: CGFloat = (host.bounds.height - sepH) / 2.0
        var x: CGFloat = pad

        gearButton.frame = NSRect(x: x, y: y, width: size, height: size)
        x += size + pad

        separator.frame = NSRect(x: x, y: sepY, width: 1, height: sepH)
        x += 1 + pad

        claudeButton.frame = NSRect(x: x, y: y, width: size, height: size)
        x += size + pad

        gitGraphButton.frame = NSRect(x: x, y: y, width: size, height: size)
        x += size + pad

        host.frame = NSRect(x: 0, y: 0, width: x, height: host.bounds.height)
    }

    @objc private func gearTapped() {
        sidebarVC?.presentSettingsMenu(from: gearButton)
    }

    @objc private func claudeTapped() {
        sidebarVC?.launchClaudeForCurrentSelection()
    }

    @objc private func gitGraphTapped() {
        actionDelegate?.momentermTitlebarAccessoryDidTapGitGraph()
    }
}

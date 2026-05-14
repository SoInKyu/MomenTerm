//
//  MomentermFileTreeHeaderActions.swift
//  iTerm2
//
//  4-icon header actions (new file / new folder / refresh / collapse all)
//  reused by both the right-side file tree panel and the inline sidebar tree.
//  Rules: no Auto Layout, autoresizingMask only.
//

import AppKit

@objc protocol MomentermFileTreeHeaderActionsDelegate: AnyObject {
    func fileTreeActionsDidRequestNewFile()
    func fileTreeActionsDidRequestNewFolder()
    func fileTreeActionsDidRequestRefresh()
    func fileTreeActionsDidRequestCollapseAll()
}

@objc final class MomentermFileTreeHeaderActions: NSView {

    @objc weak var delegate: MomentermFileTreeHeaderActionsDelegate?

    private let buttonSize: CGFloat = 20
    private let gap: CGFloat = 4

    private var newFileButton: NSButton!
    private var newFolderButton: NSButton!
    private var refreshButton: NSButton!
    private var collapseButton: NSButton!

    /// Total width needed to render the 4 icons (no outside padding).
    @objc static var intrinsicWidth: CGFloat { 20 * 4 + 4 * 3 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildButtons()
        layoutButtons()
    }

    required init?(coder: NSCoder) { it_fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        layoutButtons()
    }

    private func buildButtons() {
        newFileButton = makeButton(symbol: "doc.badge.plus",
                                   tooltip: "새 파일",
                                   action: #selector(newFileTapped))
        newFolderButton = makeButton(symbol: "folder.badge.plus",
                                     tooltip: "새 폴더",
                                     action: #selector(newFolderTapped))
        refreshButton = makeButton(symbol: "arrow.clockwise",
                                   tooltip: "새로고침",
                                   action: #selector(refreshTapped))
        collapseButton = makeButton(symbol: "rectangle.compress.vertical",
                                    tooltip: "모두 접기",
                                    action: #selector(collapseTapped))
        addSubview(newFileButton)
        addSubview(newFolderButton)
        addSubview(refreshButton)
        addSubview(collapseButton)
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyUpOrDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = .secondaryLabelColor
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        return btn
    }

    private func layoutButtons() {
        let s = buttonSize
        let y = (bounds.height - s) / 2.0
        var x: CGFloat = 0
        for btn in [newFileButton, newFolderButton, refreshButton, collapseButton] {
            btn?.frame = NSRect(x: x, y: y, width: s, height: s)
            x += s + gap
        }
    }

    @objc private func newFileTapped() { delegate?.fileTreeActionsDidRequestNewFile() }
    @objc private func newFolderTapped() { delegate?.fileTreeActionsDidRequestNewFolder() }
    @objc private func refreshTapped() { delegate?.fileTreeActionsDidRequestRefresh() }
    @objc private func collapseTapped() { delegate?.fileTreeActionsDidRequestCollapseAll() }
}

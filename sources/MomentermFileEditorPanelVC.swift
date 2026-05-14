//
//  MomentermFileEditorPanelVC.swift
//  iTerm2
//
//  Reusable text editor used in the right-side panel slot (Git Graph–style
//  embedding). Single persistent instance per window: the host calls
//  setFileURL(_:) to switch files. Provides save (Cmd+S), markdown preview
//  toggle for .md, detach-to-floating-window, and a close button that asks
//  the delegate to hide the panel.
//  Rules: no Auto Layout for the outer layout, autoresizingMask only,
//  it_fatalError not fatalError.
//

import AppKit
import WebKit

private final class HandCursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@objc(MomentermFileEditorPanelDelegate)
protocol MomentermFileEditorPanelDelegate: AnyObject {
    /// Toggle whether the panel is embedded inline or in its own floating window.
    func momentermFileEditorPanelRequestDetachToggle()

    /// Close (hide) the panel.
    func momentermFileEditorPanelRequestClose()
}

@objc final class MomentermFileEditorPanelVC: NSViewController {

    @objc weak var delegate: MomentermFileEditorPanelDelegate?

    @objc var isDetached: Bool = false {
        didSet { refreshDetachButtonIcon() }
    }

    private var fileURL: URL
    private var titleLabel: NSTextField!
    private var saveBtn: NSButton!
    private var detachBtn: NSButton!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var isDirty = false
    private var previewBtn: NSButton!
    private var webView: WKWebView?
    private var isPreviewMode = false
    private var isMarkdown: Bool { fileURL.pathExtension.lowercased() == "md" }
    private var hasLoadedFile: Bool { fileURL.path != "/dev/null" }

    // SF Symbol helpers
    private static func iconBtn(symbol: String, desc: String, size: CGFloat = 14) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        btn.contentTintColor = .secondaryLabelColor
        return btn
    }

    /// Zero-arg init for the panel use case. Call `setFileURL(_:)` to load a file.
    @objc override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) { it_fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view = v
        buildSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if hasLoadedFile {
            loadFileContent()
        }
        refreshChrome()
    }

    // MARK: - Build

    private func buildSubviews() {
        let w = view.bounds.width
        let h = view.bounds.height
        let barH: CGFloat = 44

        // ── Top bar ─────────────────────────────────────────────
        let bar = NSView(frame: NSRect(x: 0, y: h - barH, width: w, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bar.autoresizingMask = [.width, .minYMargin]

        // Layout (right → left): [X close 20] [10] [detach 20] [10] [save btn 48] [10] [preview 20] [10] [label fills rest]
        let iconSz: CGFloat = 20
        let saveBtnW: CGFloat = 48
        let btnH: CGFloat = 22
        let pad: CGFloat = 10
        var nextX = w - pad - iconSz   // X close

        // X close button (rightmost)
        let closeBtn = Self.iconBtn(symbol: "xmark.circle.fill", desc: "닫기", size: 14)
        closeBtn.frame = NSRect(x: nextX, y: (barH - iconSz) / 2, width: iconSz, height: iconSz)
        closeBtn.autoresizingMask = .minXMargin
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        bar.addSubview(closeBtn)
        nextX -= pad + iconSz

        // Detach toggle button
        let detachButton = Self.iconBtn(symbol: "rectangle.portrait.and.arrow.right", desc: "분리", size: 13)
        detachButton.frame = NSRect(x: nextX, y: (barH - iconSz) / 2, width: iconSz, height: iconSz)
        detachButton.autoresizingMask = .minXMargin
        detachButton.target = self
        detachButton.action = #selector(detachTapped)
        bar.addSubview(detachButton)
        detachBtn = detachButton
        nextX -= pad + saveBtnW

        // Save text button
        let saveBtnView = HandCursorButton(frame: NSRect(x: nextX, y: (barH - btnH) / 2, width: saveBtnW, height: btnH))
        saveBtnView.title = "저장"
        saveBtnView.bezelStyle = .rounded
        saveBtnView.autoresizingMask = .minXMargin
        saveBtnView.keyEquivalent = "s"
        saveBtnView.keyEquivalentModifierMask = [.command]
        saveBtnView.target = self
        saveBtnView.action = #selector(saveTapped)
        bar.addSubview(saveBtnView)
        saveBtn = saveBtnView
        nextX -= pad + iconSz

        // Preview icon button (eye) — always created, hidden when not .md.
        let pvBtn = Self.iconBtn(symbol: "doc.text.magnifyingglass", desc: "미리보기", size: 14)
        pvBtn.frame = NSRect(x: nextX, y: (barH - iconSz) / 2, width: iconSz, height: iconSz)
        pvBtn.autoresizingMask = .minXMargin
        pvBtn.target = self
        pvBtn.action = #selector(togglePreview)
        bar.addSubview(pvBtn)
        previewBtn = pvBtn
        nextX -= pad + iconSz

        // Filename label (fills remaining left space)
        let fnLabel = NSTextField(labelWithString: hasLoadedFile ? fileURL.lastPathComponent : "")
        fnLabel.frame = NSRect(x: 8, y: (barH - 20) / 2, width: nextX - 8, height: 20)
        fnLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fnLabel.lineBreakMode = .byTruncatingMiddle
        fnLabel.autoresizingMask = .width
        bar.addSubview(fnLabel)
        titleLabel = fnLabel

        view.addSubview(bar)

        // ── Separator ────────────────────────────────────────────
        let sep = NSBox(frame: NSRect(x: 0, y: h - barH - 1, width: w, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]
        view.addSubview(sep)

        // ── Scroll + TextView ────────────────────────────────────
        let tvH = h - barH - 1
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: tvH))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: tvH))
        tv.autoresizingMask = [.width, .height]
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: tvH)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = self
        scrollView.documentView = tv
        view.addSubview(scrollView)
        textView = tv

        refreshDetachButtonIcon()
    }

    private func refreshChrome() {
        // Toggle widgets that depend on having a real file loaded.
        previewBtn.isHidden = !isMarkdown
        saveBtn.isEnabled = hasLoadedFile
    }

    private func refreshDetachButtonIcon() {
        guard detachBtn != nil else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let symbol = isDetached ? "rectangle.portrait.and.arrow.forward" : "rectangle.portrait.and.arrow.right"
        detachBtn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        detachBtn.toolTip = isDetached ? "터미널 창으로 다시 붙이기" : "별도 창으로 분리"
    }

    // MARK: - Public

    /// Replace the currently shown file. Prompts to save / discard if dirty.
    /// Returns false if the user cancelled the switch.
    @discardableResult
    @objc func setFileURL(_ newURL: URL) -> Bool {
        if isDirty {
            let a = NSAlert()
            a.messageText = "저장하지 않은 내용이 있습니다."
            a.informativeText = "\u{201C}\(fileURL.lastPathComponent)\u{201D}의 변경 내용을 저장하시겠습니까?"
            a.addButton(withTitle: "저장")
            a.addButton(withTitle: "버리기")
            a.addButton(withTitle: "취소")
            let r = a.runModal()
            if r == .alertThirdButtonReturn { return false }
            if r == .alertFirstButtonReturn { saveFile() }
            isDirty = false
        }
        fileURL = newURL
        if isViewLoaded {
            loadFileContent()
            titleLabel.stringValue = newURL.lastPathComponent
            refreshChrome()
            // Switching files exits preview so the new content drives the view.
            if isPreviewMode {
                isPreviewMode = false
                hideWebPreview()
                previewBtn.image = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                                           accessibilityDescription: "미리보기")
            }
        }
        return true
    }

    private func loadFileContent() {
        textView.string = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        isDirty = false
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        saveFile()
    }

    private func saveFile() {
        guard hasLoadedFile else { return }
        do {
            try textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
            isDirty = false
            // Brief checkmark feedback
            saveBtn.title = "✓ 저장됨"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.saveBtn.title = "저장"
            }
        } catch {
            let a = NSAlert()
            a.messageText = "저장 실패"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func closeTapped() {
        if isDirty {
            let a = NSAlert()
            a.messageText = "저장하지 않은 내용이 있습니다."
            a.informativeText = "\u{201C}\(fileURL.lastPathComponent)\u{201D}의 변경 내용을 저장하시겠습니까?"
            a.addButton(withTitle: "저장")
            a.addButton(withTitle: "버리기")
            a.addButton(withTitle: "취소")
            let r = a.runModal()
            if r == .alertFirstButtonReturn { saveFile() }
            else if r == .alertThirdButtonReturn { return }
            isDirty = false
        }
        delegate?.momentermFileEditorPanelRequestClose()
    }

    @objc private func detachTapped() {
        delegate?.momentermFileEditorPanelRequestDetachToggle()
    }

    @objc private func togglePreview() {
        guard isMarkdown else { return }
        isPreviewMode.toggle()
        // Swap icon: eye = "click to preview", pencil = "click to edit"
        previewBtn.image = NSImage(systemSymbolName: isPreviewMode ? "square.and.pencil" : "doc.text.magnifyingglass",
                                   accessibilityDescription: isPreviewMode ? "편집" : "미리보기")
        isPreviewMode ? showWebPreview() : hideWebPreview()
    }

    private func showWebPreview() {
        let wv = WKWebView(frame: scrollView.frame)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        view.addSubview(wv)
        let html = iTermBrowserTemplateLoader.load(template: "MomentermMarkdownTemplate.html")
        wv.loadHTMLString(html, baseURL: nil)
        scrollView.isHidden = true
        webView = wv
    }

    private func hideWebPreview() {
        webView?.removeFromSuperview()
        webView = nil
        scrollView.isHidden = false
    }

    private func injectMarkdownContent(_ wv: WKWebView) {
        guard let d = try? JSONEncoder().encode(textView.string),
              let s = String(data: d, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.__setContent(\(s))", completionHandler: nil)
    }
}

// MARK: - NSTextViewDelegate

extension MomentermFileEditorPanelVC: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard hasLoadedFile else { return }
        isDirty = true
    }
}

// MARK: - WKNavigationDelegate

extension MomentermFileEditorPanelVC: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectMarkdownContent(webView)
    }
}

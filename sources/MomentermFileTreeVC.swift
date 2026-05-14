//
//  MomentermFileTreeVC.swift
//  iTerm2
//
//  File tree panel — shows project files in a tree and allows inline editing.
//  Appears to the right of the sidebar when "세부 파일보기" is triggered.
//  Rules: no Auto Layout, autoresizingMask only, it_fatalError not fatalError.
//

import AppKit

// MARK: - Delegate

@objc protocol MomentermEmbeddedFileTreeDelegate: AnyObject {
    func fileTreeDidRequestClose()
    func fileTreeDidRequestOpenEditorAtPath(_ path: String)
}

// MARK: - View Controller
// File node model + filter live in MomentermFileOperations.swift (MtFileNode + MtFileFilter).

@objc final class MomentermFileTreeVC: NSViewController {

    @objc weak var fileTreeDelegate: MomentermEmbeddedFileTreeDelegate?

    // MARK: - Layout constants
    private let kPanelW: CGFloat   = 240
    private let kHeaderH: CGFloat  = 36
    private let kSepH: CGFloat     = 1
    private let kEditorBarH: CGFloat = 28
    private let kEditorBodyH: CGFloat = 172
    private var editorTotalH: CGFloat { editorIsOpen ? kEditorBarH + kEditorBodyH : 0 }

    // MARK: - UI refs
    private var headerView: NSView!
    private var headerSeparator: NSBox!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var headerActions: MomentermFileTreeHeaderActions!
    private var treeScrollView: NSScrollView!
    private var outlineView: NSOutlineView!
    private var editorSeparator: NSBox!
    private var editorBar: NSView!
    private var editorFileLabel: NSTextField!
    private var editorSaveBtn: NSButton!
    private var editorCloseBtn: NSButton!
    private var editorScrollView: NSScrollView!
    private var textView: NSTextView!
    private var leftBorderBox: NSBox!
    private var rightBorderBox: NSBox!

    // MARK: - State
    private var rootNode: MtFileNode!
    private var currentFileURL: URL?
    private var isDirty = false
    private var editorIsOpen = false
    private let rootPath: String
    private let projectName: String

    // MARK: - Floating editor panel state
    private var floatingPanel: NSPanel?
    private var floatingFilenameLabel: NSTextField!
    private var floatingSaveBtn: NSButton!
    private var floatingTextView: NSTextView!
    private var floatingCurrentURL: URL?
    private var floatingIsDirty = false

    // MARK: - Init

    @objc init(rootPath: String, projectName: String) {
        self.rootPath = rootPath
        self.projectName = projectName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { it_fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle

    override func loadView() {
        rootNode = MtFileNode(url: URL(fileURLWithPath: rootPath), isDirectory: true)
        MomentermFileOperations.loadChildren(of: rootNode)
        let frame = NSRect(x: 0, y: 0, width: kPanelW, height: 400)
        view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        if rootNode.children?.isEmpty == false {
            outlineView.expandItem(rootNode)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyLayout()
    }

    // MARK: - Build

    private func buildSubviews() {
        let w = kPanelW

        // ── Header ──────────────────────────────────────────
        let header = NSView(frame: NSRect(x: 0, y: 0, width: w, height: kHeaderH))
        header.autoresizingMask = [.width, .minYMargin]

        titleLabel = NSTextField(labelWithString: projectName)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = .width
        header.addSubview(titleLabel)

        closeButton = NSButton(frame: .zero)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "닫기")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.autoresizingMask = [.minXMargin]
        header.addSubview(closeButton)

        headerActions = MomentermFileTreeHeaderActions(frame: .zero)
        headerActions.delegate = self
        headerActions.autoresizingMask = [.minXMargin]
        header.addSubview(headerActions)

        view.addSubview(header)
        headerView = header

        // ── Separator ────────────────────────────────────────
        headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        headerSeparator.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerSeparator)

        // ── Outline (file tree) ──────────────────────────────
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 10
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(fileClicked)
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileCol"))
        col.isEditable = false
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        treeScrollView = NSScrollView()
        treeScrollView.hasVerticalScroller = true
        treeScrollView.autohidesScrollers = true
        treeScrollView.drawsBackground = false
        treeScrollView.documentView = outlineView
        view.addSubview(treeScrollView)

        // ── Editor separator ─────────────────────────────────
        editorSeparator = NSBox()
        editorSeparator.boxType = .separator
        editorSeparator.autoresizingMask = [.width, .minYMargin]
        editorSeparator.isHidden = true
        view.addSubview(editorSeparator)

        // ── Editor bar ───────────────────────────────────────
        editorBar = NSView()
        editorBar.autoresizingMask = [.width, .minYMargin]
        editorBar.isHidden = true

        editorFileLabel = NSTextField(labelWithString: "")
        editorFileLabel.font = .systemFont(ofSize: 11, weight: .medium)
        editorFileLabel.lineBreakMode = .byTruncatingMiddle
        editorFileLabel.autoresizingMask = .width

        editorSaveBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 54, height: 20))
        editorSaveBtn.title = "저장"
        editorSaveBtn.bezelStyle = .rounded
        editorSaveBtn.controlSize = .small
        editorSaveBtn.keyEquivalent = "s"
        editorSaveBtn.keyEquivalentModifierMask = [.command]
        editorSaveBtn.target = self
        editorSaveBtn.action = #selector(saveTapped)
        editorSaveBtn.autoresizingMask = [.minXMargin]

        editorCloseBtn = NSButton(frame: .zero)
        editorCloseBtn.isBordered = false
        editorCloseBtn.imagePosition = .imageOnly
        editorCloseBtn.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "편집 닫기")
        editorCloseBtn.contentTintColor = .secondaryLabelColor
        editorCloseBtn.target = self
        editorCloseBtn.action = #selector(closeEditor)
        editorCloseBtn.autoresizingMask = [.minXMargin]

        editorBar.addSubview(editorFileLabel)
        editorBar.addSubview(editorSaveBtn)
        editorBar.addSubview(editorCloseBtn)
        view.addSubview(editorBar)

        // ── Editor text view ─────────────────────────────────
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: kPanelW, height: kEditorBodyH))
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: kEditorBodyH)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: kPanelW, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        editorScrollView = NSScrollView()
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.documentView = textView
        editorScrollView.isHidden = true
        view.addSubview(editorScrollView)

        // Left border — separates file tree from sidebar
        leftBorderBox = NSBox()
        leftBorderBox.boxType = .custom
        leftBorderBox.borderWidth = 0
        leftBorderBox.fillColor = NSColor.gridColor
        view.addSubview(leftBorderBox)

        // Right border — separates file tree from terminal area
        rightBorderBox = NSBox()
        rightBorderBox.boxType = .custom
        rightBorderBox.borderWidth = 0
        rightBorderBox.fillColor = NSColor.gridColor
        view.addSubview(rightBorderBox)
    }

    private func applyLayout() {
        let w = view.bounds.width
        let h = view.bounds.height

        // Header at top
        let actionsW = MomentermFileTreeHeaderActions.intrinsicWidth
        let closeX = w - 28
        let actionsX = closeX - actionsW - 6
        headerView.frame = NSRect(x: 0, y: h - kHeaderH, width: w, height: kHeaderH)
        titleLabel.frame = NSRect(x: 10, y: (kHeaderH - 16) / 2,
                                   width: max(0, actionsX - 14), height: 16)
        headerActions.frame = NSRect(x: actionsX, y: (kHeaderH - 20) / 2,
                                     width: actionsW, height: 20)
        closeButton.frame = NSRect(x: closeX, y: (kHeaderH - 20) / 2, width: 20, height: 20)

        // Separator just below header
        headerSeparator.frame = NSRect(x: 0, y: h - kHeaderH - kSepH, width: w, height: kSepH)

        let treeBottom: CGFloat = editorTotalH
        let treeTop: CGFloat = h - kHeaderH - kSepH

        // Tree scroll view
        treeScrollView.frame = NSRect(x: 0, y: treeBottom, width: w, height: max(0, treeTop - treeBottom))
        outlineView.tableColumns.first?.width = w - 4

        // Left and right borders framing the panel
        leftBorderBox.frame  = NSRect(x: 0,     y: 0, width: 1, height: h)
        rightBorderBox.frame = NSRect(x: w - 1, y: 0, width: 1, height: h)

        // Editor section
        if editorIsOpen {
            editorSeparator.frame = NSRect(x: 0, y: editorTotalH - kSepH, width: w, height: kSepH)
            editorBar.frame = NSRect(x: 0, y: editorTotalH - kSepH - kEditorBarH, width: w, height: kEditorBarH)
            editorFileLabel.frame = NSRect(x: 8, y: (kEditorBarH - 14) / 2, width: w - 108, height: 14)
            editorSaveBtn.frame = NSRect(x: w - 84, y: (kEditorBarH - 20) / 2, width: 56, height: 20)
            editorCloseBtn.frame = NSRect(x: w - 26, y: (kEditorBarH - 20) / 2, width: 20, height: 20)
            editorScrollView.frame = NSRect(x: 0, y: 0, width: w, height: kEditorBodyH)
        }
    }

    private func setEditorOpen(_ open: Bool) {
        editorIsOpen = open
        editorSeparator.isHidden = !open
        editorBar.isHidden = !open
        editorScrollView.isHidden = !open
        view.needsLayout = true
        applyLayout()
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        if isDirty {
            let a = NSAlert()
            a.messageText = "저장하지 않은 내용이 있습니다."
            a.informativeText = "파일 트리를 닫으면 변경 내용이 손실됩니다."
            a.addButton(withTitle: "저장하고 닫기")
            a.addButton(withTitle: "버리고 닫기")
            a.addButton(withTitle: "취소")
            let r = a.runModal()
            if r == .alertFirstButtonReturn { saveCurrentFile() }
            else if r == .alertThirdButtonReturn { return }
        }
        fileTreeDelegate?.fileTreeDidRequestClose()
    }

    @objc private func fileClicked() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? MtFileNode,
              !node.isDirectory else { return }
        fileTreeDelegate?.fileTreeDidRequestOpenEditorAtPath(node.url.path)
    }

    private func openEditorForURL(_ url: URL) {
        // If switching files with unsaved changes, ask
        if isDirty, currentFileURL != url {
            let a = NSAlert()
            a.messageText = "저장하지 않은 내용이 있습니다."
            a.informativeText = "\u{201C}\(currentFileURL?.lastPathComponent ?? "")\u{201D}의 변경 내용을 저장하시겠습니까?"
            a.addButton(withTitle: "저장")
            a.addButton(withTitle: "버리기")
            a.addButton(withTitle: "취소")
            let r = a.runModal()
            if r == .alertFirstButtonReturn { saveCurrentFile() }
            else if r == .alertThirdButtonReturn { return }
            isDirty = false
        }
        currentFileURL = url
        textView.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        editorFileLabel.stringValue = url.lastPathComponent
        editorSaveBtn.title = "저장"
        isDirty = false
        if !editorIsOpen { setEditorOpen(true) }
    }

    @objc private func saveTapped() {
        saveCurrentFile()
    }

    private func saveCurrentFile() {
        guard let url = currentFileURL else { return }
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            editorSaveBtn.title = "저장됨 ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.editorSaveBtn.title = "저장"
            }
        } catch {
            let a = NSAlert()
            a.messageText = "저장 실패"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func closeEditor() {
        if isDirty {
            let a = NSAlert()
            a.messageText = "저장하지 않은 내용이 있습니다."
            a.addButton(withTitle: "저장")
            a.addButton(withTitle: "버리기")
            a.addButton(withTitle: "취소")
            let r = a.runModal()
            if r == .alertFirstButtonReturn { saveCurrentFile() }
            else if r == .alertThirdButtonReturn { return }
        }
        isDirty = false
        currentFileURL = nil
        setEditorOpen(false)
    }
}

// MARK: - NSOutlineViewDataSource

extension MomentermFileTreeVC: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? MtFileNode) ?? rootNode
        if node?.children == nil, let node = node { MomentermFileOperations.loadChildren(of: node) }
        return node?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? MtFileNode) ?? rootNode!
        if node.children == nil { MomentermFileOperations.loadChildren(of: node) }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MtFileNode)?.isDirectory ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension MomentermFileTreeVC: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? MtFileNode else { return nil }

        let id = NSUserInterfaceItemIdentifier("MtFileCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
            cell.subviews.forEach { $0.removeFromSuperview() }
        } else {
            cell = NSTableCellView()
        }
        cell.identifier = id

        let icon = NSImageView(frame: NSRect(x: 2, y: 2, width: 14, height: 14))
        icon.autoresizingMask = []
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbolName(for: node), accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        cell.addSubview(icon)

        let label = NSTextField(labelWithString: node.displayName)
        label.font = .systemFont(ofSize: 11)
        label.autoresizingMask = .width
        label.frame = NSRect(x: 20, y: 2,
                              width: max(0, outlineView.bounds.width - 20), height: 16)
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label)
        cell.textField = label

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? MtFileNode else { return false }
        return !node.isDirectory
    }

    private func symbolName(for node: MtFileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch node.url.pathExtension.lowercased() {
        case "swift":                      return "swift"
        case "m", "h", "c", "cpp", "cc":  return "c.square"
        case "js", "jsx":                  return "j.square"
        case "ts", "tsx":                  return "t.square"
        case "json":                       return "curlybraces"
        case "md", "markdown":             return "doc.text"
        case "sh", "zsh", "bash":          return "terminal"
        case "png", "jpg", "jpeg",
             "gif", "svg", "ico",
             "webp":                       return "photo"
        case "pdf":                        return "doc.richtext"
        default:
            let name = node.url.lastPathComponent.lowercased()
            if name.hasPrefix(".env") { return "key.fill" }
            return "doc"
        }
    }
}

// MARK: - NSTextViewDelegate

extension MomentermFileTreeVC: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === floatingTextView {
            floatingIsDirty = true
        } else {
            isDirty = true
        }
    }
}

// MARK: - Floating Editor Panel

extension MomentermFileTreeVC: NSWindowDelegate {

    func openFloatingEditor(for url: URL) {
        if floatingIsDirty, floatingCurrentURL != url {
            let a = NSAlert()
            a.messageText = "저장하지 않은 내용이 있습니다."
            a.informativeText = "\u{201C}\(floatingCurrentURL?.lastPathComponent ?? "")\u{201D}의 변경 내용을 저장하시겠습니까?"
            a.addButton(withTitle: "저장")
            a.addButton(withTitle: "버리기")
            a.addButton(withTitle: "취소")
            let r = a.runModal()
            if r == .alertFirstButtonReturn { saveFloatingFile() }
            else if r == .alertThirdButtonReturn { return }
            floatingIsDirty = false
        }

        if floatingPanel == nil { buildFloatingPanel() }

        floatingCurrentURL = url
        floatingFilenameLabel.stringValue = url.lastPathComponent
        floatingTextView.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        floatingSaveBtn.title = "저장"
        floatingIsDirty = false
        floatingPanel?.title = url.lastPathComponent
        floatingPanel?.makeKeyAndOrderFront(nil)
    }

    private func buildFloatingPanel() {
        let w: CGFloat = 640
        let h: CGFloat = 480
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered,
                            defer: false)
        panel.delegate = self

        guard let cv = panel.contentView else { return }

        // Top bar
        let barH: CGFloat = 32
        let bar = NSView(frame: NSRect(x: 0, y: h - barH, width: w, height: barH))
        bar.autoresizingMask = [.width, .minYMargin]

        let fnLabel = NSTextField(labelWithString: "")
        fnLabel.frame = NSRect(x: 8, y: 6, width: w - 100, height: 20)
        fnLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fnLabel.lineBreakMode = .byTruncatingMiddle
        fnLabel.autoresizingMask = .width
        bar.addSubview(fnLabel)
        floatingFilenameLabel = fnLabel

        let saveBtn = NSButton(frame: NSRect(x: w - 88, y: 5, width: 80, height: 22))
        saveBtn.title = "저장"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "s"
        saveBtn.keyEquivalentModifierMask = [.command]
        saveBtn.target = self
        saveBtn.action = #selector(floatingSaveTapped)
        saveBtn.autoresizingMask = .minXMargin
        bar.addSubview(saveBtn)
        floatingSaveBtn = saveBtn
        cv.addSubview(bar)

        // Separator
        let sep = NSBox(frame: NSRect(x: 0, y: h - barH - 1, width: w, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(sep)

        // Text area
        let tvH = h - barH - 1
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: tvH))
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
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = self
        scrollView.documentView = tv
        cv.addSubview(scrollView)
        floatingTextView = tv

        panel.center()
        floatingPanel = panel
    }

    @objc private func floatingSaveTapped() {
        saveFloatingFile()
    }

    private func saveFloatingFile() {
        guard let url = floatingCurrentURL else { return }
        do {
            try floatingTextView.string.write(to: url, atomically: true, encoding: .utf8)
            floatingIsDirty = false
            floatingSaveBtn.title = "저장됨 ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.floatingSaveBtn.title = "저장"
            }
        } catch {
            let a = NSAlert()
            a.messageText = "저장 실패"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard floatingIsDirty else { return true }
        let a = NSAlert()
        a.messageText = "저장하지 않은 내용이 있습니다."
        a.informativeText = "\u{201C}\(floatingCurrentURL?.lastPathComponent ?? "")\u{201D}의 변경 내용을 저장하시겠습니까?"
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "버리기")
        a.addButton(withTitle: "취소")
        let r = a.runModal()
        if r == .alertFirstButtonReturn { saveFloatingFile(); return true }
        else if r == .alertSecondButtonReturn { floatingIsDirty = false; return true }
        return false
    }
}

// MARK: - Context menu + CRUD + Refresh + Collapse

extension MomentermFileTreeVC: NSMenuDelegate, MomentermFileTreeHeaderActionsDelegate {

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outlineView.clickedRow
        if clicked >= 0, let node = outlineView.item(atRow: clicked) as? MtFileNode {
            // File / folder context: rename + trash, plus contextual create + refresh
            let rename = NSMenuItem(title: "이름 변경",
                                    action: #selector(menuRename(_:)), keyEquivalent: "")
            rename.representedObject = node
            rename.target = self
            menu.addItem(rename)

            let trash = NSMenuItem(title: "휴지통으로 이동",
                                   action: #selector(menuTrash(_:)), keyEquivalent: "")
            trash.representedObject = node
            trash.target = self
            menu.addItem(trash)

            if node.isDirectory {
                menu.addItem(NSMenuItem.separator())
                let newFile = NSMenuItem(title: "새 파일…",
                                         action: #selector(menuNewFileInFolder(_:)), keyEquivalent: "")
                newFile.representedObject = node
                newFile.target = self
                menu.addItem(newFile)

                let newFolder = NSMenuItem(title: "새 폴더…",
                                           action: #selector(menuNewFolderInFolder(_:)), keyEquivalent: "")
                newFolder.representedObject = node
                newFolder.target = self
                menu.addItem(newFolder)
            }

            menu.addItem(NSMenuItem.separator())
            let refresh = NSMenuItem(title: "새로고침",
                                     action: #selector(menuRefresh(_:)), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
        } else {
            // Empty area: root-level create actions
            let newFile = NSMenuItem(title: "새 파일…",
                                     action: #selector(menuNewFileInRoot(_:)), keyEquivalent: "")
            newFile.target = self
            menu.addItem(newFile)

            let newFolder = NSMenuItem(title: "새 폴더…",
                                       action: #selector(menuNewFolderInRoot(_:)), keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)

            menu.addItem(NSMenuItem.separator())
            let refresh = NSMenuItem(title: "새로고침",
                                     action: #selector(menuRefresh(_:)), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)

            let collapse = NSMenuItem(title: "모두 접기",
                                      action: #selector(menuCollapseAll(_:)), keyEquivalent: "")
            collapse.target = self
            menu.addItem(collapse)
        }
    }

    // MARK: Menu actions

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode else { return }
        promptRename(node)
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode else { return }
        confirmAndTrash(node)
    }

    @objc private func menuNewFileInFolder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode else { return }
        promptCreate(parentDir: node.url, isFolder: false)
    }

    @objc private func menuNewFolderInFolder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode else { return }
        promptCreate(parentDir: node.url, isFolder: true)
    }

    @objc private func menuNewFileInRoot(_ sender: NSMenuItem) {
        promptCreate(parentDir: rootNode.url, isFolder: false)
    }

    @objc private func menuNewFolderInRoot(_ sender: NSMenuItem) {
        promptCreate(parentDir: rootNode.url, isFolder: true)
    }

    @objc private func menuRefresh(_ sender: NSMenuItem) { refreshTree() }

    @objc private func menuCollapseAll(_ sender: NSMenuItem) { collapseAll() }

    // MARK: MomentermFileTreeHeaderActionsDelegate

    func fileTreeActionsDidRequestNewFile() {
        promptCreate(parentDir: currentTargetDirectory(), isFolder: false)
    }

    func fileTreeActionsDidRequestNewFolder() {
        promptCreate(parentDir: currentTargetDirectory(), isFolder: true)
    }

    func fileTreeActionsDidRequestRefresh() { refreshTree() }

    func fileTreeActionsDidRequestCollapseAll() { collapseAll() }

    // MARK: Target resolution

    /// Resolves the directory that a header-bar "new file/folder" action targets.
    /// Priority: selected directory → parent of selected file → root.
    private func currentTargetDirectory() -> URL {
        let row = outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? MtFileNode {
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }
        return rootNode.url
    }

    // MARK: Prompts

    private func promptCreate(parentDir: URL, isFolder: Bool) {
        let alert = NSAlert()
        alert.messageText = isFolder ? "새 폴더" : "새 파일"
        alert.informativeText = "\u{201C}\((parentDir.path as NSString).abbreviatingWithTildeInPath)\u{201D} 안에 만들기"
        alert.addButton(withTitle: "만들기")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = isFolder ? "새 폴더" : "untitled.txt"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        do {
            let url: URL
            if isFolder {
                url = try MomentermFileOperations.createFolder(in: parentDir, name: name)
            } else {
                url = try MomentermFileOperations.createFile(in: parentDir, name: name)
            }
            refreshTree(revealing: url)
        } catch {
            presentFileOpError(error)
        }
    }

    private func promptRename(_ node: MtFileNode) {
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(node.displayName)\u{201D} 이름 변경"
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = node.displayName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let newURL = try MomentermFileOperations.rename(node.url, to: field.stringValue)
            refreshTree(revealing: newURL)
        } catch {
            presentFileOpError(error)
        }
    }

    private func confirmAndTrash(_ node: MtFileNode) {
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(node.displayName)\u{201D}을(를) 휴지통으로 이동하시겠습니까?"
        alert.informativeText = "휴지통에서 복원할 수 있습니다."
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MomentermFileOperations.moveToTrash(node.url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.refreshTree()
            case .failure(let error):
                self.presentFileOpError(error)
            }
        }
    }

    private func presentFileOpError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    // MARK: Refresh / Collapse

    /// Refreshes the tree from the filesystem while preserving expansion state
    /// (where the same paths still exist). Optionally selects and scrolls to
    /// `revealing` if provided.
    func refreshTree(revealing: URL? = nil) {
        let expandedPaths = collectExpandedPaths()
        rootNode.children = nil
        MomentermFileOperations.loadChildren(of: rootNode)
        outlineView.reloadData()
        // Re-expand root and preserved paths.
        outlineView.expandItem(nil, expandChildren: false)
        reExpand(paths: expandedPaths, in: rootNode)
        if let target = revealing { selectAndScroll(to: target) }
    }

    private func collectExpandedPaths() -> Set<String> {
        var paths: Set<String> = []
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? MtFileNode,
                  node.isDirectory,
                  outlineView.isItemExpanded(node) else { continue }
            paths.insert(node.url.path)
        }
        return paths
    }

    private func reExpand(paths: Set<String>, in node: MtFileNode) {
        guard node.isDirectory else { return }
        if node.children == nil { MomentermFileOperations.loadChildren(of: node) }
        for child in node.children ?? [] where child.isDirectory {
            if paths.contains(child.url.path) {
                outlineView.expandItem(child)
                reExpand(paths: paths, in: child)
            }
        }
    }

    private func selectAndScroll(to url: URL) {
        // Walk the visible tree, expanding parents along the way.
        let components = url.standardizedFileURL.pathComponents
        let rootComponents = rootNode.url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else { return }
        var current: MtFileNode = rootNode
        for component in components.dropFirst(rootComponents.count) {
            if current.children == nil { MomentermFileOperations.loadChildren(of: current) }
            guard let next = current.children?.first(where: { $0.displayName == component }) else { return }
            if next.url.standardizedFileURL == url.standardizedFileURL {
                let row = outlineView.row(forItem: next)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }
                return
            }
            outlineView.expandItem(next)
            current = next
        }
    }

    func collapseAll() {
        // Collapse every top-level (and transitively, children) node.
        for child in rootNode.children ?? [] where child.isDirectory {
            outlineView.collapseItem(child, collapseChildren: true)
        }
    }
}

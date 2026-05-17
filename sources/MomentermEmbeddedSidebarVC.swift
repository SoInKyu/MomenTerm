//
//  MomentermEmbeddedSidebarVC.swift
//  iTerm2
//
//  Created by MomenTerm on 2026-04-19.
//  Embedded left-sidebar for the terminal window.
//  Rules: no Auto Layout, no fatalError, no NSUserDefaults (use iTermUserDefaults).

import AppKit

// MARK: - Delegate

@objc protocol MomentermEmbeddedSidebarDelegate: AnyObject {
    /// Called when the user opens a project from the sidebar.
    /// `projectId` is the MomentermProject.id, used to register the newly-created
    /// session with MomentermSessionRegistry so it can be found later by single-click.
    func sidebarDidRequestOpenProject(path: String, spaceName: String, projectName: String, projectId: String, inNewTab: Bool, aiCommand: String?)
    /// Called when the user requests the file tree panel for a project.
    func sidebarDidRequestShowFileTree(path: String, projectName: String)
    /// Called when the user clicks a file inside an inline-expanded project
    /// tree. The host should load `filePath` into the right-side file editor
    /// panel (reusing the existing editor wiring used by the file-tree panel).
    func sidebarDidRequestOpenFile(filePath: String, projectPath: String, projectName: String)
    /// Called by single-click. If a live session is registered for `projectId`, the host
    /// must activate that window/tab/session and return true; if no live session exists,
    /// return false so the sidebar can fall through to its default behavior (select-only).
    @discardableResult
    func sidebarDidRequestActivateExistingSession(projectId: String) -> Bool
    /// Called by the bottom-strip Claude affordance. If a live session exists for
    /// `projectId`, the host must focus it, write `command` to its PTY, and return
    /// true; otherwise return false so the sidebar opens a fresh tab seeded with
    /// the command instead. The difference from `…ActivateExistingSession` is the
    /// injected text — `…ActivateExistingSession` just focuses, while this method
    /// also runs `command` in the focused session.
    @objc optional func sidebarDidRequestRunInExistingSession(projectId: String,
                                                              command: String) -> Bool
}

// MARK: - WorkspaceCellView (hover "+" button)

private final class WorkspaceCellView: NSTableCellView {
    private(set) var addBtn: NSButton!
    private var trackArea: NSTrackingArea?
    var addAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addBtn = NSButton()
        addBtn.isBordered = false
        addBtn.imagePosition = .imageOnly
        addBtn.image = NSImage(systemSymbolName: "plus.circle",
                               accessibilityDescription: "프로젝트 추가")
        addBtn.contentTintColor = .tertiaryLabelColor
        addBtn.target = self
        addBtn.action = #selector(addTapped)
        addBtn.alphaValue = 0
        addSubview(addBtn)
    }
    required init?(coder: NSCoder) { it_fatalError("init(coder:) not supported") }

    @objc private func addTapped() { addAction?() }

    func positionAddButton() {
        let s: CGFloat = 14
        addBtn.frame = NSRect(x: bounds.width - s - 4, y: (bounds.height - s) / 2.0, width: s, height: s)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackArea { removeTrackingArea(ta); trackArea = nil }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        trackArea = ta
        addTrackingArea(ta)
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.addBtn.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.addBtn.animator().alphaValue = 0
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        addBtn.alphaValue = 0
        addAction = nil
    }
}

// MARK: - ProjectCellView (hover-revealed inline action strip)

/// Project row cell whose 4-icon inline action strip fades in on hover.
/// The strip is owned by the cell but the buttons inside are configured by
/// the sidebar VC via `setActionStrip(_:)`. AI / folder badges remain visible
/// at all times so per-project actions (e.g. Claude Code launch) stay reachable.
private final class ProjectCellView: NSTableCellView {
    private(set) var actionStrip: NSView?
    private var trackArea: NSTrackingArea?
    /// When true the strip is rendered at full opacity and hover tracking is
    /// skipped — used in inline mode where the IDE-style action icons live
    /// permanently next to the project name.
    private var actionStripAlwaysVisible = false

    /// 4pt left-edge color bar shown for the project whose session is currently
    /// active. Separate from NSOutlineView's selection highlight so the user can
    /// see at a glance which project they're working on even when another row is
    /// selected. nil = no bar (project is not active).
    private var accentBar: NSView?

    func setAccentBar(color: NSColor?) {
        if let color = color {
            if accentBar == nil {
                let bar = NSView()
                bar.wantsLayer = true
                bar.layer?.cornerRadius = 1
                accentBar = bar
                addSubview(bar, positioned: .below, relativeTo: nil)
            }
            accentBar?.layer?.backgroundColor = color.cgColor
            accentBar?.isHidden = false
            needsLayout = true
        } else {
            accentBar?.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        if let bar = accentBar, !bar.isHidden {
            bar.frame = NSRect(x: 0, y: 2, width: 3, height: max(0, bounds.height - 4))
        }
    }

    func setActionStrip(_ strip: NSView?, alwaysVisible: Bool = false) {
        actionStrip?.removeFromSuperview()
        actionStrip = strip
        actionStripAlwaysVisible = alwaysVisible
        if let strip = strip {
            strip.alphaValue = alwaysVisible ? 1 : 0
            addSubview(strip)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackArea { removeTrackingArea(ta); trackArea = nil }
        // No hover fade needed when the strip is permanently visible.
        guard !actionStripAlwaysVisible else { return }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard !actionStripAlwaysVisible, let strip = actionStrip else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            strip.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard !actionStripAlwaysVisible, let strip = actionStrip else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            strip.animator().alphaValue = 0
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        actionStrip?.removeFromSuperview()
        actionStrip = nil
        actionStripAlwaysVisible = false
        accentBar?.isHidden = true
    }
}

// MARK: - FileNodeCellView (inline file/folder rows)

/// File/folder row cell whose label re-anchors itself in `layout()`. We do
/// the positioning here (instead of relying on autoresizingMask) because
/// NSOutlineView can snap cell.frame to the real row width *after* the first
/// paint during an expand animation — a known macOS quirk that left labels
/// invisible on freshly-expanded rows until a manual refresh fired a layout
/// pass. Re-laying out on every `layout()` makes the cell self-correcting.
private final class FileNodeCellView: NSTableCellView {
    override func layout() {
        super.layout()
        guard let label = textField, label.superview === self else { return }
        label.frame = NSRect(x: 22, y: 2,
                             width: max(0, bounds.width - 26),
                             height: 16)
    }
}

// MARK: - DropOverlayView (custom, high-visibility drop indicator)

/// Transparent overlay drawn above the outline view during a sidebar drag.
/// Shows a soft workspace highlight and a subtle insertion line. Kept very
/// low-contrast on purpose — the built-in gap indicator is invisible for
/// empty workspaces and flickers when `setDropItem` remaps, so the overlay
/// exists solely to give the user a quiet, consistent visual anchor.
private final class DropOverlayView: NSView {
    struct Guide {
        /// Line rect in this overlay's (flipped) coordinate space.
        let lineRect: NSRect
        /// Workspace header rect (in this overlay's coords) to highlight, or nil.
        let workspaceRect: NSRect?
    }

    var guide: Guide? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = guide else { return }
        let accent = NSColor.controlAccentColor

        if let ws = g.workspaceRect {
            let p = NSBezierPath(roundedRect: ws.insetBy(dx: 2, dy: 1),
                                 xRadius: 5, yRadius: 5)
            accent.withAlphaComponent(0.08).setFill()
            p.fill()
            accent.withAlphaComponent(0.22).setStroke()
            p.lineWidth = 1
            p.stroke()
        }

        let line = g.lineRect
        accent.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: line,
                     xRadius: line.height / 2.0,
                     yRadius: line.height / 2.0).fill()
    }
}

// MARK: - MtSidebarOutlineView (hooks drag lifecycle to clear overlay)

private final class MtSidebarOutlineView: NSOutlineView {
    var dragStateDidClear: (() -> Void)?

    // NOTE: `draggingExited`, `draggingEnded`, and `concludeDragOperation` are
    // *optional* `NSDraggingDestination` methods with no default implementation
    // on NSView/NSTableView. Calling `super` on any of them forwards all the
    // way to NSObject's default handler, which crashes with an unrecognized
    // selector ("Trace/BPT trap: 5"). Override-only; DO NOT call super.

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragStateDidClear?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragStateDidClear?()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dragStateDidClear?()
    }
}

// MARK: - SidebarItem

private enum SidebarItem {
    case space(MomentermProjectSpace)
    case project(MomentermProject, space: MomentermProjectSpace)
}

// MARK: - File-view mode (panel vs inline)

/// How the per-project file tree is presented.
///   - panel:  right-side floating panel (legacy / default).
///   - inline: VS Code / Antigravity-style — files appear directly below the
///             project row in the sidebar's own outline view.
@objc enum MtSidebarFileViewMode: Int {
    case panel  = 0
    case inline = 1

    fileprivate static let userDefaultsKey = "MtSidebarFileViewMode"

    fileprivate static var current: MtSidebarFileViewMode {
        get {
            // First-install default is .inline (IDE-style). A user that explicitly
            // picks .panel will have rawValue 0 persisted, so this fallback only
            // kicks in when nothing was ever stored.
            let raw = iTermUserDefaults.userDefaults().object(forKey: userDefaultsKey) as? Int
            return MtSidebarFileViewMode(rawValue: raw ?? 1) ?? .inline
        }
        set {
            iTermUserDefaults.userDefaults().set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}

// MARK: - DropTarget (shared computation result for validate + accept)

private struct DropTarget {
    let destSpaceId: String
    let destSpaceName: String
    let insertIndex: Int
    let aboveName: String?
    let belowName: String?
    /// Item/childIndex values to pass to NSOutlineView.setDropItem.
    let dropItem: Any
    let dropChildIndex: Int
    /// Line rect in OUTLINE VIEW coordinates (flipped).
    let lineRectInOutline: NSRect
    /// Workspace header rect in OUTLINE VIEW coordinates (flipped).
    let workspaceRectInOutline: NSRect?
}

// MARK: - View Controller

@objc final class MomentermEmbeddedSidebarVC: NSViewController {

    @objc weak var sidebarDelegate: MomentermEmbeddedSidebarDelegate?

    /// When true, double-clicking a project bypasses the "새 탭 / 새 창" dialog
    /// and opens immediately. Set by hosts (e.g. the welcome window) that have
    /// no existing terminal window to tab into.
    @objc var suppressProjectOpenDialog = false

    private var store: MomentermProjectStore = MomentermProjectStorage.shared.load()
    private var filteredItems: [SidebarItem]?  // nil → full tree; non-nil → flat filtered list

    /// projectId → root MtFileNode for inline-expanded projects.
    /// Reference identity matters for NSOutlineView item caching, so we hand the
    /// same MtFileNode instances back from the data source repeatedly.
    private var expandedFileTrees: [String: MtFileNode] = [:]

    private var searchField: NSSearchField!
    private var addButton: NSButton!
    private var separator: NSBox!
    /// Last view used to anchor the settings menu — the title-bar gear button.
    /// Stored weakly so guide/shortcuts popovers (opened from menu items that
    /// fire AFTER the menu has dismissed) can still find a sensible anchor.
    private weak var lastSettingsAnchor: NSView?
    private var outlineView: MtSidebarOutlineView!
    private var scrollView: NSScrollView!
    private var dropOverlay: DropOverlayView!
    private var emptyStateView: NSView!
    private var keyMonitor: Any?
    /// Temporary strong reference to keep the path-picker trampoline alive during a modal alert.
    private var _retainedPathPicker: AnyObject?

    /// Temporary strong reference for the AI tool picker trampoline.
    private var _retainedAITrampoline: AIToolPickerTrampoline?

    /// Guard for the cold-launch workspace expand. NSOutlineView ignores
    /// `expandItem(nil)` calls issued before its first layout pass, so we have
    /// a viewDidAppear-time safety net that fires exactly once.
    private var didCompleteInitialExpand = false

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if MtSidebarFileViewMode.current == .inline {
            populateAllInlineFileTrees()
        }
        outlineView.reloadData()
        expandAllWorkspaces()
        // Safety net A: next runloop, still in viewDidLoad context. Helps in
        // most cases but is not enough on a true cold launch where the view
        // hasn't been attached to a window yet.
        DispatchQueue.main.async { [weak self] in
            self?.expandAllWorkspaces()
        }

        // Cmd+Opt+O → 세부 파일보기
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if mods == [.command, .option],
               event.charactersIgnoringModifiers?.lowercased() == "o" {
                self.openFileTreeForSelectedOrActiveProject()
                return nil
            }
            return event
        }
    }

    deinit {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Safety net B: the window-attached signal. NSOutlineView only starts
        // its real layout pass once the view is in a window, so an
        // expandItem(nil) issued during viewDidLoad can be silently dropped
        // on cold launch. Reissue here, exactly once.
        guard !didCompleteInitialExpand else { return }
        didCompleteInitialExpand = true
        expandAllWorkspaces()
    }

    // MARK: - Setup

    private func setupUI() {
        let w: CGFloat = 220

        // Search field — top left
        searchField = NSSearchField(frame: NSRect(x: 8, y: 0, width: w - 64, height: 22))
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "검색..."
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.controlSize = .small
        view.addSubview(searchField)

        // "+" button — rightmost. The settings gear moved to the title-bar
        // accessory view (see MomentermTitlebarAccessoryVC); the space it
        // vacated is left as breathing room rather than collapsed.
        addButton = NSButton(frame: NSRect(x: w - 28, y: 1, width: 20, height: 20))
        addButton.autoresizingMask = [.minXMargin, .minYMargin]
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "새 Workspace")
        addButton.target = self
        addButton.action = #selector(addSpaceTapped)
        view.addSubview(addButton)

        // Separator between search bar and list
        separator = NSBox(frame: NSRect(x: 0, y: 0, width: w, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        view.addSubview(separator)

        // Scroll view below the top bar
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: 400 - 28))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        outlineView = MtSidebarOutlineView()
        outlineView.style = .sourceList
        outlineView.rowHeight = 22
        // Tight indent — paired with dropping the left "</>" icon in inline
        // mode, this reclaims ~8px so longer project names fit before "…".
        outlineView.indentationPerLevel = 8
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        // IDE-style: single-click on a file node opens the right-side editor;
        // single-click on a folder node toggles its expansion. Project rows
        // intentionally do nothing on single-click — the double-click handler
        // below preserves the "new tab vs new window" choice prompt.
        outlineView.action = #selector(sidebarRowClicked)
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.dragStateDidClear = { [weak self] in
            self?.dropOverlay?.guide = nil
        }

        let ctxMenu = NSMenu()
        ctxMenu.delegate = self
        outlineView.menu = ctxMenu

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarCol"))
        col.isEditable = false
        col.minWidth = 100
        // Fixed column width — purposely NOT auto-resizing to the scroll view.
        // The sidebar can be hosted in the welcome window (legacy scrollers,
        // ~15px reserved) or in the terminal window (overlay scrollers, 0px
        // reserved). If we let the column autoresize, cell.bounds.width
        // ends up 205 vs 220 in those two hosts and the trailing icons
        // (refresh + AI badge), which are anchored to cell.bounds.width - 4,
        // visibly slide ~15px rightward when the user transitions to the
        // terminal — and feel like they're clipping against the boundary.
        // Pinning to 205 keeps the icons at a constant x (= 201) across hosts,
        // matching the welcome window's layout the user reads as canonical.
        col.width = w - 15
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.registerForDraggedTypes([MomentermEmbeddedSidebarVC.projectDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // We draw our own indicator; disable the built-in one so the two don't fight.
        outlineView.draggingDestinationFeedbackStyle = .none

        scrollView.documentView = outlineView
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        view.addSubview(scrollView)

        // Transparent overlay that sits on top of the scroll view and draws the
        // drop line + workspace highlight + label during a drag. Because it
        // hit-tests through, NSOutlineView still receives the drag events.
        dropOverlay = DropOverlayView(frame: scrollView.frame)
        dropOverlay.autoresizingMask = [.width, .height]
        view.addSubview(dropOverlay, positioned: .above, relativeTo: scrollView)

        emptyStateView = buildEmptyStateView(width: w)
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView, positioned: .above, relativeTo: scrollView)

        positionControls()
        updateEmptyStateVisibility()
    }

    private func buildEmptyStateView(width: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true

        let pad: CGFloat = 16
        let contentW = width - pad * 2
        let block1Y: CGFloat = 140
        let block2Y: CGFloat = 40

        let line1 = NSTextField(labelWithString: "열린 폴더가 없습니다.")
        line1.frame = NSRect(x: pad, y: block1Y + 40, width: contentW, height: 18)
        line1.autoresizingMask = [.width, .minYMargin]
        line1.textColor = .secondaryLabelColor
        line1.font = .systemFont(ofSize: 12)
        line1.alignment = .left
        line1.lineBreakMode = .byWordWrapping
        line1.maximumNumberOfLines = 2
        container.addSubview(line1)

        let openBtn = NSButton(title: "폴더 열기", target: nil, action: nil)
        openBtn.frame = NSRect(x: pad, y: block1Y, width: contentW, height: 32)
        openBtn.autoresizingMask = [.width, .minYMargin]
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .large
        openBtn.keyEquivalent = "\r"
        openBtn.target = self
        openBtn.action = #selector(emptyStateOpenFolderTapped)
        container.addSubview(openBtn)

        let line2 = NSTextField(labelWithString: "저장소를 로컬에 복제할 수 있습니다.")
        line2.frame = NSRect(x: pad, y: block2Y + 40, width: contentW, height: 18)
        line2.autoresizingMask = [.width, .minYMargin]
        line2.textColor = .secondaryLabelColor
        line2.font = .systemFont(ofSize: 12)
        line2.alignment = .left
        line2.lineBreakMode = .byWordWrapping
        line2.maximumNumberOfLines = 2
        container.addSubview(line2)

        let cloneBtn = NSButton(title: "저장소 복제", target: nil, action: nil)
        cloneBtn.frame = NSRect(x: pad, y: block2Y, width: contentW, height: 32)
        cloneBtn.autoresizingMask = [.width, .minYMargin]
        cloneBtn.bezelStyle = .rounded
        cloneBtn.controlSize = .large
        cloneBtn.target = self
        cloneBtn.action = #selector(emptyStateCloneRepoTapped)
        container.addSubview(cloneBtn)

        return container
    }

    private func positionControls() {
        let h = view.bounds.height
        let w = view.bounds.width
        let topH: CGFloat = 36   // search bar height — matches file tree kHeaderH
        let sepH: CGFloat = 1
        searchField.frame    = NSRect(x: 8, y: h - topH + 7, width: w - 40, height: 22)
        addButton.frame      = NSRect(x: w - 28, y: h - topH + 8, width: 20, height: 20)
        separator.frame      = NSRect(x: 0, y: h - topH - sepH, width: w, height: sepH)
        scrollView.frame     = NSRect(x: 0, y: 0, width: w, height: h - topH - sepH)
        dropOverlay?.frame   = scrollView.frame
        emptyStateView?.frame = scrollView.frame
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionControls()
    }

    // MARK: - Data

    @objc func reloadData() {
        store = MomentermProjectStorage.shared.load()
        applyFilter(query: searchField?.stringValue ?? "")
        updateEmptyStateVisibility()
    }

    private func updateEmptyStateVisibility() {
        let isEmpty = store.spaces.isEmpty
        emptyStateView?.isHidden = !isEmpty
        scrollView?.isHidden = isEmpty
        dropOverlay?.isHidden = isEmpty
    }

    /// MomentermProject.id of the project whose session is currently active in the
    /// host terminal. Drives the left-edge accent bar on the matching row, so the
    /// user can see at a glance which project they're working on — independent of
    /// the transient row selection. `nil` = no project is active.
    private var activeProjectId: String?

    /// Selects the sidebar row whose project path matches `path` AND marks that
    /// project as the "active" one (for the accent-bar highlight). Called from
    /// PseudoTerminal whenever the key terminal session/tab/window changes.
    @objc func selectProjectForPath(_ path: String) {
        guard !path.isEmpty else { return }
        let resolved = (path as NSString).resolvingSymlinksInPath
        var matchedProjectId: String?
        var matchedRow: Int = -1
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .project(let project, _) = item else { continue }
            let projResolved = (project.path as NSString).resolvingSymlinksInPath
            if projResolved == resolved {
                matchedProjectId = project.id
                matchedRow = row
                break
            }
        }
        updateActiveProject(id: matchedProjectId)
        // Selection only updates when we're not in filter mode — otherwise the user
        // would jump out of their search context every time they switch tabs.
        if filteredItems == nil, matchedRow >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: matchedRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(matchedRow)
        }
    }

    /// Same as `selectProjectForPath` but takes the project ID directly. Preferred
    /// over the path-based path when the caller knows which project a session
    /// belongs to via `MomentermSessionRegistry`.
    @objc func setActiveProjectId(_ projectId: String?) {
        updateActiveProject(id: projectId)
        guard filteredItems == nil, let projectId = projectId, !projectId.isEmpty else { return }
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .project(let project, _) = item, project.id == projectId else { continue }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            return
        }
    }

    /// Updates the accent bar on the visible project rows. We avoid reloadData
    /// because that drops the file-tree expansion state — instead we walk visible
    /// rows and re-apply the accent on each ProjectCellView, which is O(visible).
    private func updateActiveProject(id newId: String?) {
        let oldId = activeProjectId
        guard oldId != newId else { return }
        activeProjectId = newId
        refreshAccentBars()
    }

    private func refreshAccentBars() {
        let visibleRange = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRange.length > 0 else { return }
        for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .project(let project, let space) = item else { continue }
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCellView else { continue }
            if project.id == activeProjectId {
                cell.setAccentBar(color: colorForSpaceName(space.name))
            } else {
                cell.setAccentBar(color: nil)
            }
        }
    }

    /// Unified accent color for the active-project bar. A muted khaki — calm enough
    /// to live in the sidebar permanently without competing with the user's content,
    /// distinctive enough to read at a glance against the system-default selection
    /// highlight. We deliberately do NOT vary by space (the per-space tab color in
    /// the terminal area already provides that signal); a single soft tone keeps
    /// the sidebar visually quiet.
    private func colorForSpaceName(_ spaceName: String) -> NSColor {
        _ = spaceName
        return NSColor(red: 0.52, green: 0.48, blue: 0.30, alpha: 0.80)
    }

    private func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filteredItems = nil
            // Keep inline trees in sync with store mutations (project add/remove/move):
            // drop entries whose project is gone, then pre-load any newly added ones.
            if MtSidebarFileViewMode.current == .inline {
                pruneStaleInlineFileTrees()
                populateAllInlineFileTrees()
            }
            outlineView.reloadData()
            expandAllWorkspaces()
            return
        }
        // Search flattens the tree and hides per-project file children.
        if !expandedFileTrees.isEmpty { expandedFileTrees.removeAll() }
        var results: [SidebarItem] = []
        for space in store.spaces {
            if space.name.lowercased().contains(q) {
                results.append(.space(space))
            }
            for project in space.projects where project.name.lowercased().contains(q) {
                results.append(.project(project, space: space))
            }
        }
        filteredItems = results
        outlineView.reloadData()
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter(query: sender.stringValue)
    }

    @objc private func addSpaceTapped() {
        openFolderAsWorkspace()
    }

    @objc private func emptyStateOpenFolderTapped() {
        openFolderAsWorkspace()
    }

    @objc private func emptyStateCloneRepoTapped() {
        cloneRepositoryAsWorkspace()
    }

    /// Single-click handler for the sidebar outline view.
    ///   • Folder file node → toggle expansion (IDE behaviour).
    ///   • File file node   → load into the right-side editor via the host.
    ///   • Anything else (project/workspace rows) → ignored, so double-click
    ///     and dedicated badge buttons remain the way to trigger their actions.
    @objc private func sidebarRowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }

        // Project row: single click activates an already-open tab/window for this
        // project (if any). If no live session matches, fall through to the default
        // NSOutlineView selection behavior — the user can still double-click to open
        // a new tab/window. This is the "한 번 클릭 = 기존 작업으로 이동" half of the
        // single/double-click split.
        let sidebarItem: SidebarItem?
        if let filtered = filteredItems {
            sidebarItem = (row < filtered.count) ? filtered[row] : nil
        } else {
            sidebarItem = outlineView.item(atRow: row) as? SidebarItem
        }
        if let sidebarItem, case .project(let project, _) = sidebarItem {
            _ = sidebarDelegate?.sidebarDidRequestActivateExistingSession(projectId: project.id)
            return
        }

        guard let item = outlineView.item(atRow: row) else { return }
        guard let node = item as? MtFileNode else { return }
        if node.isDirectory {
            // Animate the expand/collapse so the tree feels alive instead of
            // snapping. animator() proxy + an explicit duration is enough —
            // NSOutlineView handles the row fade/slide for us.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                if outlineView.isItemExpanded(node) {
                    outlineView.animator().collapseItem(node)
                } else {
                    outlineView.animator().expandItem(node)
                }
            }
            return
        }
        guard let projectId = projectIdContaining(node: node) else { return }
        guard let project = store.spaces.flatMap({ $0.projects }).first(where: { $0.id == projectId }) else { return }
        sidebarDelegate?.sidebarDidRequestOpenFile(filePath: node.url.path,
                                                  projectPath: project.path,
                                                  projectName: project.name)
    }

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }

        let item: SidebarItem?
        if let filtered = filteredItems {
            guard row < filtered.count else { return }
            item = filtered[row]
        } else {
            item = outlineView.item(atRow: row) as? SidebarItem
        }
        guard let item = item, case .project(let project, let space) = item else { return }

        // In welcome-window context there is no existing terminal to tab into,
        // so skip the choice dialog and open directly.
        if suppressProjectOpenDialog {
            sidebarDelegate?.sidebarDidRequestOpenProject(path: project.path,
                                                         spaceName: space.name,
                                                         projectName: project.name,
                                                         projectId: project.id,
                                                         inNewTab: false,
                                                         aiCommand: nil)
            return
        }

        // If a tab/window is already open for this project, jump straight to it.
        // Otherwise create a new tab and auto-launch the project's AI command —
        // double-click is the single entry point now that the per-row star icon
        // has been removed.
        if sidebarDelegate?.sidebarDidRequestActivateExistingSession(projectId: project.id) == true {
            return
        }

        sidebarDelegate?.sidebarDidRequestOpenProject(path: project.path,
                                                     spaceName: space.name,
                                                     projectName: project.name,
                                                     projectId: project.id,
                                                     inNewTab: true,
                                                     aiCommand: project.aiLaunchCommand)
    }

    // MARK: - Settings Popover and Menu

    /// Pops the sidebar settings menu beneath `anchor`. The title-bar
    /// `MomentermTitlebarAccessoryVC` calls this with its own gear button as
    /// the anchor, and the anchor is stashed so guide/shortcut popovers
    /// (opened by menu items that fire AFTER the menu closes) keep a
    /// sensible relative position.
    @objc func presentSettingsMenu(from anchor: NSView) {
        lastSettingsAnchor = anchor
        let menu = NSMenu()

        let guideItem = NSMenuItem(title: "MomenTerm 사용 가이드", action: #selector(showUserGuidePopover), keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        let shortcutsItem = NSMenuItem(title: "키보드 단축키", action: #selector(showShortcutsPopover), keyEquivalent: "")
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)

        menu.addItem(NSMenuItem.separator())

        let passkeyTitle = MomentermPasskeyManager.shared.isPasskeySet ? "패스키 변경/해제" : "패스키 설정"
        let passkeyItem = NSMenuItem(title: passkeyTitle, action: #selector(managePasskey), keyEquivalent: "")
        passkeyItem.target = self
        menu.addItem(passkeyItem)

        menu.addItem(NSMenuItem.separator())

        // 파일 보기 방식 — 우측 패널 vs 인라인 펼침
        let viewModeMenu = NSMenu()
        let currentMode = MtSidebarFileViewMode.current
        let panelItem = NSMenuItem(title: "우측 패널",
                                   action: #selector(setFileViewModePanel),
                                   keyEquivalent: "")
        panelItem.target = self
        panelItem.state = (currentMode == .panel) ? .on : .off
        viewModeMenu.addItem(panelItem)

        let inlineItem = NSMenuItem(title: "인라인 펼침",
                                    action: #selector(setFileViewModeInline),
                                    keyEquivalent: "")
        inlineItem.target = self
        inlineItem.state = (currentMode == .inline) ? .on : .off
        viewModeMenu.addItem(inlineItem)

        let viewModeParent = NSMenuItem(title: "파일 보기 방식", action: nil, keyEquivalent: "")
        viewModeParent.submenu = viewModeMenu
        menu.addItem(viewModeParent)

        let btnFrame = anchor.convert(anchor.bounds, to: nil)
        menu.popUp(positioning: menu.items[0],
                   at: NSPoint(x: btnFrame.minX, y: btnFrame.minY),
                   in: anchor.window?.contentView)
    }

    /// Launches Claude for the project bound to the currently active terminal
    /// tab (preferred) or, failing that, the row the user has selected in the
    /// sidebar. If a live session already exists for that project the host
    /// focuses it and injects the project's AI launch command; otherwise a
    /// new tab is opened seeded with the same command. Used by the
    /// bottom-strip Claude affordance.
    @objc func launchClaudeForCurrentSelection() {
        guard let resolved = resolveClaudeTarget() else { return }
        let project = resolved.project
        let space = resolved.space
        let command = project.aiLaunchCommand ?? ""

        if !command.isEmpty,
           sidebarDelegate?.sidebarDidRequestRunInExistingSession?(projectId: project.id,
                                                                  command: command) == true {
            return
        }
        sidebarDelegate?.sidebarDidRequestOpenProject(path: project.path,
                                                     spaceName: space.name,
                                                     projectName: project.name,
                                                     projectId: project.id,
                                                     inNewTab: true,
                                                     aiCommand: project.aiLaunchCommand)
    }

    /// Picks the project the Claude affordance should target. The currently
    /// active terminal tab wins — it matches the user's mental model of
    /// "run Claude in this tab". If no tab is active (Welcome window, or a
    /// terminal whose active tab has no project mapping) we fall back to the
    /// sidebar's selected row.
    private func resolveClaudeTarget() -> (project: MomentermProject, space: MomentermProjectSpace)? {
        if let activeId = activeProjectId {
            for space in store.spaces {
                if let p = space.projects.first(where: { $0.id == activeId }) {
                    return (p, space)
                }
            }
        }
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        let item: SidebarItem?
        if let filtered = filteredItems {
            guard row < filtered.count else { return nil }
            item = filtered[row]
        } else {
            item = outlineView.item(atRow: row) as? SidebarItem
        }
        guard let item, case .project(let project, let space) = item else { return nil }
        return (project, space)
    }

    @objc private func setFileViewModePanel() {
        if MtSidebarFileViewMode.current == .panel { return }
        MtSidebarFileViewMode.current = .panel
        collapseAllInlineTrees()
    }

    @objc private func setFileViewModeInline() {
        if MtSidebarFileViewMode.current == .inline { return }
        MtSidebarFileViewMode.current = .inline
        // IDE-style: every project starts expanded with its file tree pre-loaded,
        // so users see disclosure triangles on every row immediately.
        populateAllInlineFileTrees()
        outlineView.reloadData()
        expandAllWorkspaces()
    }

    /// Expands every workspace header so its projects are visible by default,
    /// while leaving the projects themselves collapsed (no inline file tree).
    ///
    /// We iterate the visible top-level rows and feed each handle back into
    /// `expandItem(_:)` directly. `SidebarItem` is a Swift `enum` boxed via
    /// `Any` for NSOutlineView — every fresh `SidebarItem.space(...)` we build
    /// gets a new NSObject wrapper, and `expandItem`/`isItemExpanded` compare
    /// wrappers by identity. Using `outlineView.item(atRow:)` returns the exact
    /// wrapper NSOutlineView already cached, so the call hits.
    ///
    /// Reverse iteration matters: expanding workspace[0] inserts its project
    /// rows just below it, which shifts every later workspace's row index.
    /// Walking high → low keeps the captured indices valid.
    fileprivate func expandAllWorkspaces() {
        guard filteredItems == nil else { return }
        let workspaceCount = store.spaces.count
        for index in (0..<workspaceCount).reversed() {
            guard let item = outlineView.item(atRow: index) else { continue }
            outlineView.expandItem(item)
        }
    }

    /// Drops `expandedFileTrees` entries whose project no longer exists in the
    /// current store — keeps the dictionary from accumulating stale roots after
    /// a project is removed or moved between workspaces.
    fileprivate func pruneStaleInlineFileTrees() {
        let liveIds = Set(store.spaces.flatMap { $0.projects.map(\.id) })
        for key in expandedFileTrees.keys where !liveIds.contains(key) {
            expandedFileTrees.removeValue(forKey: key)
        }
    }

    /// Pre-loads the inline file tree root for every project so that
    /// `isItemExpandable` can report `true` and NSOutlineView shows a
    /// disclosure triangle on every project row without the user having to
    /// click the folder icon first. Projects whose path is missing on disk
    /// are skipped — they keep the warning badge instead of a broken tree.
    fileprivate func populateAllInlineFileTrees() {
        for space in store.spaces {
            for project in space.projects {
                if expandedFileTrees[project.id] != nil { continue }
                guard project.pathExists else { continue }
                let root = MtFileNode(url: URL(fileURLWithPath: project.path),
                                      isDirectory: true)
                MomentermFileOperations.loadChildren(of: root)
                expandedFileTrees[project.id] = root
            }
        }
    }

    /// Collapses every inline file tree and reloads — used when switching out
    /// of inline mode or before a drag (so the drop-indicator math stays valid).
    private func collapseAllInlineTrees() {
        guard !expandedFileTrees.isEmpty else {
            outlineView.reloadData()
            return
        }
        expandedFileTrees.removeAll()
        outlineView.reloadData()
        expandAllWorkspaces()
    }

    @objc private func showShortcutsPopover() {
        let popover = NSPopover()
        popover.behavior = .transient

        let sections: [(title: String, items: [(key: String, desc: String)])] = [
            ("탭/창 관리", [
                ("⌘T",    "새 탭"),
                ("⌘D",    "창 수직 분할"),
                ("⇧⌘D",  "창 수평 분할"),
                ("⌘←/→", "탭 이동 (또는 ⌘1-9)"),
                ("⌘[/]",  "분할 화면 간 이동"),
            ]),
            ("화면 조작", [
                ("⌘K",   "화면 지우기 (버퍼 초기화)"),
                ("⌘↩",  "전체 화면 전환"),
                ("⌘W",   "탭 닫기"),
            ]),
            ("MomenTerm", [
                ("⌘⌥O", "세부 파일보기"),
            ]),
            ("유용한 팁", [
                ("⌘⌥I", "모든 분할 화면 동시 입력"),
            ]),
        ]

        let w: CGFloat = 290
        let pad: CGFloat = 10
        let rowH: CGFloat = 20
        let hdrH: CGFloat = 18
        let secGap: CGFloat = 6
        let keyW: CGFloat = 52

        // Pre-compute total height
        var totalH: CGFloat = pad * 2
        for (i, sec) in sections.enumerated() {
            totalH += hdrH + CGFloat(sec.items.count) * rowH
            if i < sections.count - 1 { totalH += secGap }
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: totalH))
        var curY: CGFloat = totalH - pad   // layout top-down

        for (i, sec) in sections.enumerated() {
            curY -= hdrH
            let hdrLbl = NSTextField(labelWithString: sec.title.uppercased())
            hdrLbl.font = .systemFont(ofSize: 9, weight: .semibold)
            hdrLbl.textColor = .tertiaryLabelColor
            hdrLbl.frame = NSRect(x: pad, y: curY, width: w - pad * 2, height: hdrH - 2)
            contentView.addSubview(hdrLbl)

            for item in sec.items {
                curY -= rowH
                let keyLbl = NSTextField(labelWithString: item.key)
                keyLbl.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                keyLbl.textColor = .secondaryLabelColor
                keyLbl.alignment = .right
                keyLbl.frame = NSRect(x: pad, y: curY, width: keyW, height: rowH - 2)
                contentView.addSubview(keyLbl)

                let descLbl = NSTextField(labelWithString: item.desc)
                descLbl.font = .systemFont(ofSize: 11)
                descLbl.frame = NSRect(x: pad + keyW + 8, y: curY,
                                       width: w - pad * 2 - keyW - 8, height: rowH - 2)
                contentView.addSubview(descLbl)
            }

            if i < sections.count - 1 { curY -= secGap }
        }

        let vc = NSViewController()
        vc.view = contentView
        popover.contentViewController = vc
        popover.contentSize = contentView.frame.size
        let anchor: NSView = lastSettingsAnchor ?? view
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    // MARK: - User Guide (신규 사용자 가이드)

    @objc private func showUserGuidePopover() {
        let popover = NSPopover()
        popover.behavior = .semitransient

        let w: CGFloat = 460
        let h: CGFloat = 540

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(makeUserGuideAttributedString())

        scrollView.documentView = textView

        let vc = NSViewController()
        vc.view = scrollView
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: w, height: h)
        let anchor: NSView = lastSettingsAnchor ?? view
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func makeUserGuideAttributedString() -> NSAttributedString {
        let out = NSMutableAttributedString()

        // 단락 스타일 프리셋
        let pTitle: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 2
            return p
        }()
        let pSubtitle: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 16
            p.lineSpacing = 2
            return p
        }()
        let pSection: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = 14
            p.paragraphSpacing = 6
            return p
        }()
        let pSubhead: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = 6
            p.paragraphSpacing = 2
            return p
        }()
        let pBody: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = 4
            return p
        }()
        let pStep: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.headIndent = 20
            p.firstLineHeadIndent = 0
            p.paragraphSpacing = 3
            return p
        }()
        let pBullet: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.headIndent = 36
            p.firstLineHeadIndent = 20
            p.paragraphSpacing = 2
            return p
        }()
        let pKbd: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.tabStops = [NSTextTab(textAlignment: .left, location: 76)]
            p.defaultTabInterval = 76
            p.firstLineHeadIndent = 12
            p.headIndent = 88
            p.paragraphSpacing = 2
            return p
        }()
        let pTip: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = 6
            p.paragraphSpacing = 6
            p.lineSpacing = 2
            p.firstLineHeadIndent = 0
            p.headIndent = 22
            return p
        }()
        let pClose: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = 16
            p.lineSpacing = 3
            return p
        }()

        // 속성 프리셋
        let aTitle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pTitle,
        ]
        let aSubtitle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: pSubtitle,
        ]
        let aSection: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: pSection,
        ]
        let aSubhead: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: pSubhead,
        ]
        let aBody: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pBody,
        ]
        let aStep: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pStep,
        ]
        let aBullet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: pBullet,
        ]
        let aKbdKey: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: pKbd,
        ]
        let aKbdDesc: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pKbd,
        ]
        let aTip: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.systemTeal,
            .paragraphStyle: pTip,
        ]
        let aClose: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: pClose,
        ]

        // 헬퍼
        func appendLine(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: s + "\n", attributes: attrs))
        }
        func appendKbd(_ key: String, _ desc: String) {
            out.append(NSAttributedString(string: key, attributes: aKbdKey))
            out.append(NSAttributedString(string: "\t", attributes: aKbdKey))
            out.append(NSAttributedString(string: desc + "\n", attributes: aKbdDesc))
        }

        // ── 헤더 ──
        appendLine("MomenTerm 사용 가이드", aTitle)
        appendLine("처음 오신 것을 환영해요. 아래 1·2·3 순서대로 따라오면 5분이면 충분합니다.", aSubtitle)

        // ── 1단계 ──
        appendLine("1단계 — 폴더(스페이스) 만들기", aSection)
        appendLine("여러 프로젝트를 묶어둘 ‘폴더’를 먼저 하나 만들어요. 예) PROJECTGANJI, PROJECTCFO …", aBody)
        appendLine("1. 사이드바 위쪽의 ‘＋’ 버튼을 누릅니다.", aStep)
        appendLine("2. 폴더 이름을 입력하고 Enter — 끝!", aStep)
        appendLine("팁) 폴더 이름을 우클릭하면 ‘이름 변경’과 ‘삭제’를 할 수 있어요.", aTip)

        // ── 2단계 ──
        appendLine("2단계 — 프로젝트 등록하기", aSection)
        appendLine("폴더 안에 실제 작업할 코드 폴더(=프로젝트)를 등록합니다.", aBody)
        appendLine("1. 폴더 위에 마우스를 올리면 오른쪽 끝에 작은 ‘＋’가 살짝 나타나요. 그걸 누르거나, 폴더를 우클릭 → ‘프로젝트 생성’을 선택합니다.", aStep)
        appendLine("2. 다음 세 가지만 채우고 ‘추가’를 누릅니다.", aStep)
        appendLine("•  프로젝트 이름 (예: MyApp)", aBullet)
        appendLine("•  프로젝트 경로 (‘찾아보기’ 버튼으로 폴더 선택)", aBullet)
        appendLine("•  사용할 AI 도구 (Claude · Codex · Gemini · 로컬 LLM 중 택1)", aBullet)
        appendLine("팁) 등록한 프로젝트를 우클릭하면 ‘편집’ · ‘복제’ · ‘세부 파일보기’ · ‘삭제’를 할 수 있어요.", aTip)

        // ── 3단계 ──
        appendLine("3단계 — 폴더 펼치고 프로젝트 열기", aSection)
        appendLine("1. 폴더 왼쪽의 ▸ 아이콘을 누르면 그 안의 프로젝트들이 펼쳐집니다. (폴더 이름을 두 번 눌러도 펼쳐져요.)", aStep)
        appendLine("2. 프로젝트 이름을 한 번 누르면, 그 경로에서 새 터미널 탭이 자동으로 열려요. cd 명령을 따로 칠 필요가 없습니다.", aStep)
        appendLine("3. 같은 이름을 한 번 더 누르면 ‘세부 파일보기’ 패널이 열려, 폴더 구조와 파일 검색을 할 수 있어요.", aStep)

        // ── 단축키 ──
        appendLine("자주 쓰는 키보드 단축키", aSection)
        appendLine("익숙해지면 마우스 없이도 빠르게 이동할 수 있어요.", aBody)

        appendLine("탭 · 창 관리", aSubhead)
        appendKbd("⌘T", "새 탭")
        appendKbd("⌘D", "창 수직 분할")
        appendKbd("⇧⌘D", "창 수평 분할")
        appendKbd("⌘W", "탭 닫기")

        appendLine("이동", aSubhead)
        appendKbd("⌘1‥9", "탭 직접 선택")
        appendKbd("⌘← / →", "탭 사이 이동")
        appendKbd("⌘[ / ⌘]", "분할 화면 사이 이동")

        appendLine("화면 조작", aSubhead)
        appendKbd("⌘K", "화면 지우기 (버퍼 초기화)")
        appendKbd("⌘↩", "전체 화면 전환")

        appendLine("MomenTerm 전용", aSubhead)
        appendKbd("⌘⌥O", "세부 파일보기 열기")
        appendKbd("⌘⌥I", "모든 분할에 동시 입력")

        appendLine("팁) ⚙ → ‘키보드 단축키’ 메뉴에서 언제든 다시 볼 수 있어요.", aTip)

        // ── Git Graph ──
        appendLine("Git Graph로 커밋 이력 한눈에 보기", aSection)
        appendLine("창 맨 아래 바에 있는 ‘Git Graph’ 버튼을 누르면 현재 프로젝트의 변경 이력이 그래프로 펼쳐집니다.", aBody)
        appendLine("•  브랜치 · 머지가 시각적으로 표시돼요.", aBullet)
        appendLine("•  위쪽 검색창에 커밋 메시지·해시·작성자를 입력해 바로 찾을 수 있어요.", aBullet)
        appendLine("•  패널 오른쪽 위의 ‘분리’ 아이콘을 누르면 별도 창으로 띄울 수 있습니다.", aBullet)

        // ── Browser ──
        appendLine("Browser로 결과 바로 확인하기", aSection)
        appendLine("같은 하단 바의 ‘Browser’ 버튼을 누르면 미니 브라우저가 열려요.", aBody)
        appendLine("•  프로젝트에서 띄운 dev 서버 URL이 자동 감지되면, 그 주소로 바로 이동합니다.", aBullet)
        appendLine("•  ‘분리’ 버튼으로 외부 창에 띄울 수도 있어요.", aBullet)
        appendLine("•  Git Graph와는 한 번에 하나만 보여지므로, 필요한 패널을 토글해서 사용하세요.", aBullet)

        // ── 더 알아두면 좋은 팁 ──
        appendLine("더 알아두면 좋은 팁", aSection)
        appendLine("•  사이드바 위쪽 검색창에 이름을 입력하면 프로젝트를 바로 찾을 수 있어요.", aBullet)
        appendLine("•  ⚙ → ‘패스키 설정’ 으로 4자리 잠금을 걸 수 있어요.", aBullet)
        appendLine("•  새 탭(⌘T)은 현재 프로젝트 경로에서 시작돼요.", aBullet)
        appendLine("•  막혔다면 우클릭부터! 대부분의 동작이 컨텍스트 메뉴에 모여 있어요.", aBullet)

        // ── 마무리 ──
        appendLine("이제 시작해 볼까요? 첫 폴더부터 만들고 자유롭게 둘러보세요.", aClose)

        return out
    }

    @objc private func managePasskey() {
        if MomentermPasskeyManager.shared.isPasskeySet {
            let alert = NSAlert()
            alert.messageText = "패스키 관리"
            alert.addButton(withTitle: "패스키 변경")
            alert.addButton(withTitle: "패스키 해제")
            alert.addButton(withTitle: "취소")
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                promptSetPasskey(isChange: true)
            } else if r == .alertSecondButtonReturn {
                MomentermPasskeyManager.shared.clearPasskey()
            }
        } else {
            promptSetPasskey(isChange: false)
        }
    }

    private func promptSetPasskey(isChange: Bool) {
        let alert = NSAlert()
        alert.messageText = isChange ? "패스키 변경" : "새 패스키 설정"
        alert.informativeText = "4자리 이상 입력하세요:"
        alert.addButton(withTitle: "설정")
        alert.addButton(withTitle: "취소")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let val = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard val.count >= 4 else {
            let err = NSAlert()
            err.messageText = "너무 짧습니다. 4자리 이상 입력하세요."
            err.runModal()
            return
        }
        MomentermPasskeyManager.shared.setPasskey(val)
    }

    // MARK: - File Tree Helper (Cmd+Opt+O)

    private func openFileTreeForSelectedOrActiveProject() {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let sidebarItem: SidebarItem?
        if let filtered = filteredItems {
            guard row < filtered.count else { return }
            sidebarItem = filtered[row]
        } else {
            sidebarItem = outlineView.item(atRow: row) as? SidebarItem
        }
        guard let sidebarItem, case .project(let project, _) = sidebarItem else { return }
        sidebarDelegate?.sidebarDidRequestShowFileTree(path: project.path, projectName: project.name)
    }
}

// MARK: - NSOutlineViewDataSource

extension MomentermEmbeddedSidebarVC: NSOutlineViewDataSource {

    static let projectDragType = NSPasteboard.PasteboardType("com.momenterm.sidebar.project")

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let filtered = filteredItems {
            return item == nil ? filtered.count : 0
        }
        if item == nil { return store.spaces.count }
        if let row = item as? SidebarItem {
            switch row {
            case .space(let s):
                return s.projects.count
            case .project(let project, _):
                if MtSidebarFileViewMode.current != .inline { return 0 }
                // Lazy-load: if populateAllInlineFileTrees skipped this project at
                // startup (pathExists was false then), try now on first access.
                if expandedFileTrees[project.id] == nil, project.pathExists {
                    let root = MtFileNode(url: URL(fileURLWithPath: project.path),
                                          isDirectory: true)
                    MomentermFileOperations.loadChildren(of: root)
                    expandedFileTrees[project.id] = root
                }
                guard let root = expandedFileTrees[project.id] else { return 0 }
                if root.children == nil { MomentermFileOperations.loadChildren(of: root) }
                return root.children?.count ?? 0
            }
        }
        if let node = item as? MtFileNode, node.isDirectory {
            if node.children == nil { MomentermFileOperations.loadChildren(of: node) }
            return node.children?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let filtered = filteredItems {
            return filtered[index]
        }
        if item == nil { return SidebarItem.space(store.spaces[index]) }
        if let row = item as? SidebarItem {
            switch row {
            case .space(let s):
                return SidebarItem.project(s.projects[index], space: s)
            case .project(let project, _):
                if let root = expandedFileTrees[project.id], let children = root.children {
                    return children[index]
                }
                it_fatalError("Inline file child requested but root tree is not loaded")
            }
        }
        if let node = item as? MtFileNode, let children = node.children {
            return children[index]
        }
        it_fatalError("Unexpected item type in embedded sidebar data source")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if filteredItems != nil { return false }
        if let row = item as? SidebarItem {
            switch row {
            case .space(let s):
                return !s.projects.isEmpty
            case .project(let project, _):
                if MtSidebarFileViewMode.current == .inline {
                    // Show ▶ only when the tree is loaded and has children, or
                    // when the path exists but hasn't been loaded yet (lazy load
                    // will fire in numberOfChildrenOfItem on first expand attempt).
                    guard let root = expandedFileTrees[project.id] else {
                        return project.pathExists
                    }
                    return !(root.children?.isEmpty ?? true)
                }
                return expandedFileTrees[project.id] != nil
            }
        }
        if let node = item as? MtFileNode {
            return node.isDirectory
        }
        return false
    }

    // MARK: Drag-and-drop reordering

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard filteredItems == nil,
              let row = item as? SidebarItem,
              case .project(let project, let space) = row else { return nil }
        // Inline file trees mess up the drop-indicator math (which assumes
        // each space's projects occupy consecutive rows). Collapse them all
        // before the drag begins; the user can re-expand after the drop.
        if !expandedFileTrees.isEmpty {
            collapseAllInlineTrees()
        }
        let pb = NSPasteboardItem()
        pb.setString("\(space.id)|\(project.id)", forType: Self.projectDragType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard filteredItems == nil,
              info.draggingPasteboard.string(forType: Self.projectDragType) != nil else {
            dropOverlay?.guide = nil
            return []
        }

        guard let target = computeDropTarget(info: info,
                                             proposedItem: item,
                                             proposedIndex: index) else {
            dropOverlay?.guide = nil
            return []
        }

        // Make sure our accept call-back and indicator point to the same slot.
        outlineView.setDropItem(target.dropItem, dropChildIndex: target.dropChildIndex)

        // Translate geometry from outline-view coords into the overlay's coords
        // so the rect stays correct even when the list has scrolled.
        let lineInOverlay = dropOverlay.convert(target.lineRectInOutline, from: outlineView)
        let wsInOverlay = target.workspaceRectInOutline.map {
            dropOverlay.convert($0, from: outlineView)
        }
        dropOverlay.guide = DropOverlayView.Guide(lineRect: lineInOverlay,
                                                  workspaceRect: wsInOverlay)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        defer { dropOverlay?.guide = nil }
        guard filteredItems == nil,
              let token = info.draggingPasteboard.string(forType: Self.projectDragType) else {
            return false
        }

        // Re-derive the destination from the same helper used for the guide so
        // what-you-see is exactly what-you-get.
        guard let target = computeDropTarget(info: info,
                                             proposedItem: item,
                                             proposedIndex: index) else { return false }

        let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let (srcSpaceId, projectId) = (parts[0], parts[1])

        var s = MomentermProjectStorage.shared.load()
        guard let srcIdx = s.spaces.firstIndex(where: { $0.id == srcSpaceId }),
              let projIdx = s.spaces[srcIdx].projects.firstIndex(where: { $0.id == projectId }),
              let destIdx = s.spaces.firstIndex(where: { $0.id == target.destSpaceId })
        else { return false }

        let project = s.spaces[srcIdx].projects.remove(at: projIdx)

        // `insertIndex` is the intended insertion point in the PRE-REMOVAL array.
        // For same-space moves, the remove shifts indices above it down by 1 —
        // adjust BEFORE clamping so a first→last move doesn't land at the wrong slot.
        var insertAt = target.insertIndex
        if srcIdx == destIdx && projIdx < insertAt {
            insertAt -= 1
        }
        insertAt = min(max(0, insertAt), s.spaces[destIdx].projects.count)
        s.spaces[destIdx].projects.insert(project, at: insertAt)
        MomentermProjectStorage.shared.save(s)
        reloadData()
        return true
    }

    // MARK: Drop target computation (shared by validate + accept)

    /// Resolves a dragging cursor position into a concrete (workspace, insertion
    /// index) plus the rects needed to render the overlay. Returns nil when the
    /// drag is not over any valid drop location.
    fileprivate func computeDropTarget(info: NSDraggingInfo,
                                       proposedItem item: Any?,
                                       proposedIndex index: Int) -> DropTarget? {
        guard filteredItems == nil else { return nil }
        let localPt = outlineView.convert(info.draggingLocation, from: nil)

        // NOTE on item identity: NSOutlineView caches `id` pointers returned from
        // `child:ofItem:`. When Swift bridges our `SidebarItem` enum to `id`, each
        // bridge creates a fresh `_SwiftValue`. `row(forItem:)`/`parent(forItem:)`
        // look up items via `isEqual:`, and since our enum's associated values
        // (MomentermProject/Space structs) aren't Equatable, lookup of a *fresh*
        // box fails silently (returns -1 / nil). To keep identity intact we only
        // ever pass `item` (the original AppKit-provided Any) or items obtained
        // from `outlineView.item(atRow:)` back into NSOutlineView APIs.
        var destSpace: MomentermProjectSpace?
        var destSpaceItem: Any?
        var insertIndex: Int = -1

        if let rawItem = item, let si = rawItem as? SidebarItem {
            switch si {
            case .space(let space):
                destSpace = space
                destSpaceItem = rawItem
                if index >= 0 {
                    insertIndex = index
                } else {
                    let r = outlineView.row(forItem: rawItem)
                    if r >= 0 {
                        let rect = outlineView.rect(ofRow: r)
                        insertIndex = (localPt.y < rect.midY) ? 0 : space.projects.count
                    } else {
                        insertIndex = space.projects.count
                    }
                }
            case .project(let project, let space):
                guard let projIdx = space.projects.firstIndex(where: { $0.id == project.id })
                else { return nil }
                let r = outlineView.row(forItem: rawItem)
                guard r >= 0 else { return nil }
                // Resolve the parent space by id via numberOfRows rather than
                // parent(forItem:), which depends on item-identity equality.
                var parentRef: Any?
                for row in stride(from: r - 1, through: 0, by: -1) {
                    if let cached = outlineView.item(atRow: row),
                       let csi = cached as? SidebarItem,
                       case .space(let cs) = csi, cs.id == space.id {
                        parentRef = cached
                        break
                    }
                }
                guard let parent = parentRef else { return nil }
                let rect = outlineView.rect(ofRow: r)
                destSpace = space
                destSpaceItem = parent
                insertIndex = (localPt.y < rect.midY) ? projIdx : (projIdx + 1)
            }
        } else {
            // Dead zone between/after all rows — append to nearest workspace above.
            let cursorRow = outlineView.row(at: localPt)
            let searchFrom = cursorRow >= 0 ? cursorRow : outlineView.numberOfRows - 1
            guard searchFrom >= 0 else { return nil }
            for row in stride(from: searchFrom, through: 0, by: -1) {
                if let cached = outlineView.item(atRow: row),
                   let si = cached as? SidebarItem,
                   case .space(let space) = si {
                    destSpace = space
                    destSpaceItem = cached
                    insertIndex = space.projects.count
                    break
                }
            }
        }

        guard let space = destSpace,
              let spaceItem = destSpaceItem,
              insertIndex >= 0 else { return nil }

        // Expand the workspace so we can measure child row rects.
        if !outlineView.isItemExpanded(spaceItem) {
            outlineView.expandItem(spaceItem)
        }

        let spaceRow = outlineView.row(forItem: spaceItem)
        let workspaceRect: NSRect? = spaceRow >= 0 ? outlineView.rect(ofRow: spaceRow) : nil

        let lineRect = indicatorRectInOutline(space: space,
                                              spaceRow: spaceRow,
                                              insertIndex: insertIndex)

        let aboveName: String? = (insertIndex > 0 && insertIndex <= space.projects.count)
            ? space.projects[insertIndex - 1].name : nil
        let belowName: String? = (insertIndex < space.projects.count)
            ? space.projects[insertIndex].name : nil

        return DropTarget(destSpaceId: space.id,
                          destSpaceName: space.name,
                          insertIndex: insertIndex,
                          aboveName: aboveName,
                          belowName: belowName,
                          dropItem: spaceItem,
                          dropChildIndex: insertIndex,
                          lineRectInOutline: lineRect,
                          workspaceRectInOutline: workspaceRect)
    }

    /// Compute the drop line rect in outline-view (flipped) coordinates.
    private func indicatorRectInOutline(space: MomentermProjectSpace,
                                        spaceRow: Int,
                                        insertIndex: Int) -> NSRect {
        let thickness: CGFloat = 3
        let inset: CGFloat = 6
        let width = max(outlineView.bounds.width - inset * 2, 0)
        let x = inset

        // Spaces are rendered as single rows; their projects, when expanded,
        // occupy the rows immediately below (spaceRow+1 ... spaceRow+count).
        if space.projects.isEmpty || spaceRow < 0 {
            // Just below the space header.
            if spaceRow >= 0 {
                let sr = outlineView.rect(ofRow: spaceRow)
                return NSRect(x: x, y: sr.maxY - thickness / 2.0,
                              width: width, height: thickness)
            }
            return NSRect(x: x, y: 0, width: width, height: thickness)
        }

        let firstProjRow = spaceRow + 1
        if insertIndex <= 0 {
            let r = outlineView.rect(ofRow: firstProjRow)
            return NSRect(x: x, y: r.minY - thickness / 2.0,
                          width: width, height: thickness)
        }

        let aboveRow = firstProjRow + insertIndex - 1
        let safeRow = min(aboveRow, outlineView.numberOfRows - 1)
        let r = outlineView.rect(ofRow: safeRow)
        return NSRect(x: x, y: r.maxY - thickness / 2.0,
                      width: width, height: thickness)
    }

}

// MARK: - Drag-drop source lifecycle (clear overlay if user cancels the drag)

extension MomentermEmbeddedSidebarVC {
    // NSOutlineViewDataSource optional — called by AppKit when our drag ends.
    // Objective-C exposure is automatic because the extension conforms via the
    // earlier extension's data-source conformance.
    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        dropOverlay?.guide = nil
    }
}

// MARK: - NSOutlineViewDelegate

extension MomentermEmbeddedSidebarVC: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let row = item as? SidebarItem {
            switch row {
            case .space(let space):
                return makeCell(outlineView, text: space.name.uppercased(), symbol: "folder.fill",
                                isHeader: true, accent: false, aiTool: nil,
                                addProjectHandler: { [weak self] in self?.addProjectToSpaceCore(space) })
            case .project(let project, let space):
                let inlineExpanded = (expandedFileTrees[project.id] != nil)
                let cell = makeCell(outlineView, text: project.name, symbol: "chevron.left.slash.chevron.right",
                                    isHeader: false, accent: !project.pathExists,
                                    aiTool: project.aiTool, localBackend: project.localLLMBackend,
                                    inlineExpanded: inlineExpanded)
                if let projectCell = cell as? ProjectCellView {
                    let isActive = (project.id == activeProjectId)
                    projectCell.setAccentBar(color: isActive ? colorForSpaceName(space.name) : nil)
                }
                return cell
            }
        }
        if let node = item as? MtFileNode {
            return makeFileNodeCell(outlineView, node: node)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Belt-and-braces against a macOS quirk: during an expand animation
        // NSOutlineView can snap cell frames *after* the first paint, which
        // leaves freshly-visible **file** rows with a clipped label.
        // Reloading the expanded item kicks an immediate layout pass so the
        // rows render correctly without the user needing to hit refresh.
        //
        // Restricted to MtFileNode items: workspace/project expand events
        // don't exhibit the quirk, and reloading them at startup has been
        // observed to leave the workspace visually collapsed on first launch
        // (NSOutlineView reverses the just-fired expand under some macOS
        // versions when reloadItem races with the initial layout).
        guard let item = notification.userInfo?["NSObject"],
              item is MtFileNode else { return }
        outlineView.reloadItem(item, reloadChildren: false)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let row = item as? SidebarItem {
            if case .space = row { return false }
            return true
        }
        if let node = item as? MtFileNode {
            // Allow selection (so context-menu / new-file target works); files
            // remain harmless because we don't define a single-click action on
            // them in the sidebar. Folders are selectable too for hierarchy nav.
            _ = node
            return true
        }
        return false
    }

    // MARK: File-node cell

    private func makeFileNodeCell(_ ov: NSOutlineView, node: MtFileNode) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("MtSidebarFileCell")
        // Use the outline view width as a sane starting point. The real fix
        // for the "label clipped after expand" quirk lives in
        // FileNodeCellView.layout(), which re-anchors the label every layout
        // pass — that path is what makes a freshly-expanded row paint
        // correctly without needing a manual refresh.
        let cellW = max(ov.bounds.width, 220)
        let cell: FileNodeCellView
        if let reused = ov.makeView(withIdentifier: id, owner: nil) as? FileNodeCellView {
            cell = reused
            cell.subviews.forEach { $0.removeFromSuperview() }
        } else {
            cell = FileNodeCellView(frame: NSRect(x: 0, y: 0, width: cellW, height: 20))
        }
        cell.identifier = id
        cell.frame = NSRect(x: 0, y: 0, width: cellW, height: 20)
        cell.autoresizingMask = [.width]

        let icon = NSImageView(frame: NSRect(x: 4, y: 3, width: 14, height: 14))
        icon.autoresizingMask = []
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder.fill" : "doc",
                             accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        cell.addSubview(icon)

        let label = NSTextField(labelWithString: node.displayName)
        label.font = .systemFont(ofSize: 11)
        label.autoresizingMask = [.width]
        label.frame = NSRect(x: 22, y: 2, width: max(0, cellW - 26), height: 16)
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label)
        cell.textField = label
        return cell
    }

    private func makeCell(_ ov: NSOutlineView, text: String, symbol: String,
                          isHeader: Bool, accent: Bool,
                          aiTool: MomentermAITool? = nil,
                          localBackend: MomentermLocalLLMBackend? = nil,
                          addProjectHandler: (() -> Void)? = nil,
                          inlineExpanded: Bool = false) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(isHeader ? "MtSpaceCell" : "MtProjectCell")
        let cellW = max(ov.bounds.width, 220)
        let cell: NSTableCellView
        if isHeader {
            if let reused = ov.makeView(withIdentifier: id, owner: nil) as? WorkspaceCellView {
                cell = reused
            } else {
                cell = WorkspaceCellView(frame: NSRect(x: 0, y: 0, width: cellW, height: 24))
            }
            // Remove all subviews except the built-in addBtn
            cell.subviews.filter { $0 !== (cell as? WorkspaceCellView)?.addBtn }.forEach { $0.removeFromSuperview() }
        } else {
            if let reused = ov.makeView(withIdentifier: id, owner: nil) as? ProjectCellView {
                cell = reused
                (cell as? ProjectCellView)?.setActionStrip(nil)
                cell.subviews.forEach { $0.removeFromSuperview() }
            } else {
                cell = ProjectCellView()
                cell.frame = NSRect(x: 0, y: 0, width: cellW, height: 24)
            }
        }
        cell.identifier = id

        // Leading icon — drawn only for workspace header rows and panel-mode
        // project rows. In inline mode the disclosure triangle already gives
        // each project a clear visual anchor, so the `</>` icon is dropped to
        // reclaim ~20px for the project name (per user feedback on truncation).
        let isInlineProjectRow = !isHeader && MtSidebarFileViewMode.current == .inline
        if !isInlineProjectRow {
            let iconView = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
            iconView.autoresizingMask = []
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                iconView.image = img
            }
            iconView.contentTintColor = isHeader ? .secondaryLabelColor
                                      : (accent ? .systemRed : .controlAccentColor)
            cell.addSubview(iconView)
        }

        // Label — reserved right-side space depends on the mode:
        //   • header rows:    just enough for the hover "+" button
        //   • inline mode:    [action-strip] + [AI badge] permanently visible
        //                     next to the project name (the disclosure triangle
        //                     replaces the legacy folder icon)
        //   • panel mode:     [folder][AI] badges as before
        // The label uses truncating-tail so long project names degrade to "…"
        // instead of crashing into the right-side icons.
        // labelX:
        //   • workspace header → 24 (room for the folder.fill leading icon)
        //   • panel-mode project → 24 (room for the </> leading icon)
        //   • inline-mode project → 4 (leading icon dropped, label starts flush)
        let labelX: CGFloat = isInlineProjectRow ? 4 : 24
        let labelRightPad: CGFloat
        if isHeader {
            labelRightPad = 20
        } else if MtSidebarFileViewMode.current == .inline {
            // Reserve room for an optional warning badge anchored to the right
            // edge (only shown when the project path is missing).
            labelRightPad = 14 + 4 + 4
        } else {
            labelRightPad = 38
        }
        let label = NSTextField(labelWithString: text)
        label.autoresizingMask = .width
        label.frame = NSRect(x: labelX, y: 4, width: max(0, cell.bounds.width - labelX - labelRightPad), height: 16)
        label.font = isHeader ? .systemFont(ofSize: 10, weight: .semibold) : .systemFont(ofSize: 12)
        label.textColor = isHeader ? .secondaryLabelColor : (accent ? .systemRed : .labelColor)
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)
        cell.textField = label

        if isHeader {
            // Wire up the hover "+" button for workspace rows
            if let wc = cell as? WorkspaceCellView {
                wc.positionAddButton()
                wc.addAction = addProjectHandler
            }
            return cell
        }

        // ── Project cell right-side badges ────────────────────────────
        // Layout (right-to-left):
        //   • inline mode:  [warning?]    (no folder icon — disclosure triangle
        //                                  handles expand/collapse)
        //   • panel  mode:  [folder] [warning?]
        // The AI launch entry point moved to double-click on the project row
        // and to the title-bar Claude icon.
        let badgeSize: CGFloat = 14
        let isInlineMode = MtSidebarFileViewMode.current == .inline
        let folderX = cell.bounds.width - badgeSize - 4
        let aiX: CGFloat = isInlineMode
            ? cell.bounds.width - badgeSize - 4
            : folderX - badgeSize - 4

        // Folder icon — panel mode only. In inline mode the right-side folder
        // icon is redundant (the row's disclosure triangle expands/collapses),
        // so we drop it entirely and reclaim the width for the label.
        if !isInlineMode {
            let folderBtn = NSButton(frame: NSRect(x: folderX, y: 5, width: badgeSize, height: badgeSize))
            folderBtn.autoresizingMask = [.minXMargin]
            folderBtn.isBordered = false
            folderBtn.imagePosition = .imageOnly
            folderBtn.imageScaling = .scaleProportionallyUpOrDown
            let folderCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            let folderSymbol = inlineExpanded ? "folder.fill" : "folder"
            if let img = NSImage(systemSymbolName: folderSymbol, accessibilityDescription: "파일 보기")?
                    .withSymbolConfiguration(folderCfg) {
                folderBtn.image = img
            }
            folderBtn.contentTintColor = inlineExpanded ? .controlAccentColor : .tertiaryLabelColor
            folderBtn.target = self
            folderBtn.action = #selector(folderIconClicked(_:))
            cell.addSubview(folderBtn)
        }

        // Right-side warning badge (only when project path is missing).
        if accent {
            let warnView = NSImageView(frame: NSRect(x: aiX, y: 5, width: badgeSize, height: badgeSize))
            warnView.autoresizingMask = [.minXMargin]
            warnView.imageScaling = .scaleProportionallyUpOrDown
            warnView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "경로 없음") {
                warnView.image = img
            }
            warnView.contentTintColor = .systemRed
            cell.addSubview(warnView)
        }

        return cell
    }

    /// Handles taps on the per-project folder icon — opens the file tree
    /// (panel mode) or toggles the inline file tree (inline mode).
    @objc private func folderIconClicked(_ sender: NSButton) {
        var view: NSView? = sender
        while let v = view, !(v is NSTableCellView) { view = v.superview }
        guard let cellView = view else { return }
        let row = outlineView.row(for: cellView)
        guard row >= 0 else { return }

        let sidebarItem: SidebarItem?
        if let filtered = filteredItems {
            guard row < filtered.count else { return }
            sidebarItem = filtered[row]
        } else {
            sidebarItem = outlineView.item(atRow: row) as? SidebarItem
        }
        guard let sidebarItem, case .project(let project, _) = sidebarItem else { return }

        // Search is active: inline expansion is disabled (filteredItems flattens
        // the tree). Fall back to panel mode for a consistent search UX.
        if filteredItems != nil || MtSidebarFileViewMode.current == .panel {
            sidebarDelegate?.sidebarDidRequestShowFileTree(path: project.path, projectName: project.name)
            return
        }
        toggleInlineFileTree(for: project)
    }

    /// Expands or collapses the inline file tree for `project`. Uses reference
    /// identity (MtFileNode is a class) so NSOutlineView can cache rows.
    fileprivate func toggleInlineFileTree(for project: MomentermProject) {
        guard let projectItem = sidebarItem(forProjectId: project.id) else { return }
        if expandedFileTrees[project.id] != nil {
            // Collapse the visible rows first so NSOutlineView animates the hide,
            // then drop our backing state and reload so the cell re-renders with
            // the AI badge (instead of the inline action strip) and no triangle.
            outlineView.collapseItem(projectItem)
            expandedFileTrees.removeValue(forKey: project.id)
            outlineView.reloadItem(projectItem, reloadChildren: true)
        } else {
            let root = MtFileNode(url: URL(fileURLWithPath: project.path), isDirectory: true)
            MomentermFileOperations.loadChildren(of: root)
            expandedFileTrees[project.id] = root
            outlineView.reloadItem(projectItem, reloadChildren: true)
            outlineView.expandItem(projectItem)
        }
    }

    /// Returns the stable SidebarItem reference that NSOutlineView currently
    /// holds for `projectId`. Returns the boxed Any value retrieved via
    /// `item(atRow:)` so identity-sensitive APIs (expand/collapse) work.
    fileprivate func sidebarItem(forProjectId projectId: String) -> Any? {
        guard filteredItems == nil else { return nil }
        for row in 0..<outlineView.numberOfRows {
            if let cached = outlineView.item(atRow: row),
               let si = cached as? SidebarItem,
               case .project(let p, _) = si, p.id == projectId {
                return cached
            }
        }
        return nil
    }
}

// MARK: - NSMenuDelegate

extension MomentermEmbeddedSidebarVC: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let rawItem = outlineView.item(atRow: row)

        // MtFileNode rows (inline mode): rename / trash / new file/folder / refresh.
        if let node = rawItem as? MtFileNode {
            populateFileNodeMenu(menu, node: node)
            return
        }

        guard let item = rawItem as? SidebarItem else { return }

        switch item {
        case .space(let space):
            let createItem = NSMenuItem(title: "프로젝트 생성",
                                        action: #selector(addProjectToSpace(_:)), keyEquivalent: "")
            createItem.representedObject = space
            createItem.target = self
            menu.addItem(createItem)

            let renameItem = NSMenuItem(title: "이름 변경",
                                        action: #selector(renameSpace(_:)), keyEquivalent: "")
            renameItem.representedObject = space
            renameItem.target = self
            menu.addItem(renameItem)

            menu.addItem(NSMenuItem.separator())
            let del = NSMenuItem(title: "\u{201C}\(space.name)\u{201D} 삭제",
                                 action: #selector(deleteSpace(_:)), keyEquivalent: "")
            del.representedObject = space
            del.target = self
            menu.addItem(del)

        case .project(let project, _):
            let edit = NSMenuItem(title: "편집", action: #selector(editProject(_:)), keyEquivalent: "")
            edit.representedObject = project
            edit.target = self
            menu.addItem(edit)

            let dup = NSMenuItem(title: "복제", action: #selector(duplicateProject(_:)), keyEquivalent: "")
            dup.representedObject = project
            dup.target = self
            menu.addItem(dup)

            let fileTree = NSMenuItem(title: "세부 파일보기", action: #selector(showFileTree(_:)), keyEquivalent: "")
            fileTree.representedObject = project
            fileTree.target = self
            menu.addItem(fileTree)

            // "최근 명령어" submenu — appears only when MomentermProjectRestorer has
            // captured a previous session's shell history for this project. The
            // user can pick a command to copy it to the clipboard.
            if !project.lastCommands.isEmpty {
                let recent = NSMenuItem(title: "최근 명령어", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "최근 명령어")
                // newest first — most useful at the top of a glance
                for cmd in project.lastCommands.reversed() {
                    let item = NSMenuItem(title: cmd,
                                          action: #selector(copyRecentCommand(_:)),
                                          keyEquivalent: "")
                    item.representedObject = cmd
                    item.target = self
                    item.toolTip = "선택하면 클립보드에 복사됩니다"
                    submenu.addItem(item)
                }
                recent.submenu = submenu
                menu.addItem(recent)
            }

            // "새 파일… / 새 폴더…" — show only when this project's inline
            // tree is actually expanded. A closed project row would otherwise
            // create an unseen file, which is confusing.
            if MtSidebarFileViewMode.current == .inline,
               let projectItem = sidebarItem(forProjectId: project.id),
               outlineView.isItemExpanded(projectItem) {
                menu.addItem(NSMenuItem.separator())
                let newFile = NSMenuItem(title: "새 파일…",
                                         action: #selector(projectMenuNewFile(_:)),
                                         keyEquivalent: "")
                newFile.representedObject = project
                newFile.target = self
                menu.addItem(newFile)

                let newFolder = NSMenuItem(title: "새 폴더…",
                                           action: #selector(projectMenuNewFolder(_:)),
                                           keyEquivalent: "")
                newFolder.representedObject = project
                newFolder.target = self
                menu.addItem(newFolder)
            }

            menu.addItem(NSMenuItem.separator())
            let del = NSMenuItem(title: "\u{201C}\(project.name)\u{201D} 삭제",
                                 action: #selector(deleteProject(_:)), keyEquivalent: "")
            del.representedObject = project
            del.target = self
            menu.addItem(del)
        }
    }

    @objc private func addProjectToSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? MomentermProjectSpace else { return }
        addProjectToSpaceCore(space)
    }

    private func addProjectToSpaceCore(_ space: MomentermProjectSpace) {

        // Source state — folder selection OR pending clone.
        // Captured by reference via the picker trampoline.
        final class SourceState {
            var folderPath: String = ""
            var cloneURL: String = ""
            var cloneDestination: String = ""  // absolute path where repo will be cloned
        }
        let source = SourceState()

        let pathLabel = NSTextField(labelWithString: "프로젝트 소스")
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor

        let pathDisplay = NSTextField(labelWithString: "폴더 또는 저장소를 선택하세요")
        pathDisplay.textColor = .secondaryLabelColor
        pathDisplay.lineBreakMode = .byTruncatingMiddle
        pathDisplay.font = .systemFont(ofSize: 12)

        let folderButton = NSButton(title: "폴더 선택", target: nil, action: nil)
        folderButton.bezelStyle = .rounded

        let cloneButton = NSButton(title: "저장소 복제", target: nil, action: nil)
        cloneButton.bezelStyle = .rounded

        let aiLabel = NSTextField(labelWithString: "AI 도구")
        aiLabel.font = .systemFont(ofSize: 11)
        aiLabel.textColor = .secondaryLabelColor

        let aiPopup = NSPopUpButton()
        aiPopup.addItems(withTitles: AIToolPickerTrampoline.items)

        let statusLabel = NSTextField(labelWithString: "로컬 LLM 감지 중…")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let modelLabel = NSTextField(labelWithString: "모델")
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor

        let modelPopup = NSPopUpButton()
        modelPopup.addItem(withTitle: "감지 대기 중…")
        modelPopup.isEnabled = false

        let trampoline = AIToolPickerTrampoline(aiPopup: aiPopup, modelPopup: modelPopup, statusLabel: statusLabel)
        _retainedAITrampoline = trampoline
        trampoline.detect()

        // Manual frame layout (no Auto Layout — CLAUDE.md rule applies across all windows)
        // Layout bottom-up: y=0 is bottom of accessory view
        let w: CGFloat = 280
        modelPopup.frame   = NSRect(x: 0, y: 0,   width: w, height: 24)
        modelLabel.frame   = NSRect(x: 0, y: 28,  width: w, height: 16)
        statusLabel.frame  = NSRect(x: 0, y: 48,  width: w, height: 14)
        aiPopup.frame      = NSRect(x: 0, y: 68,  width: w, height: 24)
        aiLabel.frame      = NSRect(x: 0, y: 96,  width: w, height: 16)
        pathDisplay.frame  = NSRect(x: 0, y: 120, width: w, height: 22)
        let buttonRowY: CGFloat = 148
        let buttonH: CGFloat = 26
        let gap: CGFloat = 8
        let btnW = (w - gap) / 2
        folderButton.frame = NSRect(x: 0,           y: buttonRowY, width: btnW, height: buttonH)
        cloneButton.frame  = NSRect(x: btnW + gap,  y: buttonRowY, width: btnW, height: buttonH)
        pathLabel.frame    = NSRect(x: 0, y: buttonRowY + buttonH + 8, width: w, height: 16)

        let accessoryH: CGFloat = buttonRowY + buttonH + 8 + 16 + 4
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: w, height: accessoryH))
        stack.addSubview(modelPopup)
        stack.addSubview(modelLabel)
        stack.addSubview(statusLabel)
        stack.addSubview(aiPopup)
        stack.addSubview(aiLabel)
        stack.addSubview(pathDisplay)
        stack.addSubview(folderButton)
        stack.addSubview(cloneButton)
        stack.addSubview(pathLabel)

        let alert = NSAlert()
        alert.messageText = "\u{201C}\(space.name)\u{201D}에 프로젝트 추가"
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")
        alert.accessoryView = stack

        // NSAlert runs a nested event loop; use a trampoline NSObject so the source
        // buttons can open NSOpenPanel / nested input from within the running modal.
        final class SourcePickerTarget: NSObject {
            var folderHandler: () -> Void = {}
            var cloneHandler: () -> Void = {}
            @objc func folderTapped(_ sender: Any) { folderHandler() }
            @objc func cloneTapped(_ sender: Any) { cloneHandler() }
        }
        let picker = SourcePickerTarget()
        weak var weakDisplay = pathDisplay
        picker.folderHandler = {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "선택"
            if panel.runModal() == .OK, let url = panel.url {
                source.folderPath = url.path
                source.cloneURL = ""
                source.cloneDestination = ""
                weakDisplay?.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
                weakDisplay?.textColor = .labelColor
            }
        }
        picker.cloneHandler = { [weak self] in
            guard let self = self else { return }
            let urlAlert = NSAlert()
            urlAlert.messageText = "저장소 복제"
            urlAlert.informativeText = "복제할 저장소 URL을 입력하세요."
            urlAlert.addButton(withTitle: "다음")
            urlAlert.addButton(withTitle: "취소")
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            tf.placeholderString = "https://github.com/user/repo.git"
            urlAlert.accessoryView = tf
            guard urlAlert.runModal() == .alertFirstButtonReturn else { return }
            let raw = tf.stringValue.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return }
            guard let repoName = self.parseRepoName(from: raw) else {
                self.showSimpleAlert(messageText: "URL을 확인해 주세요",
                                     informativeText: "저장소 이름을 추출할 수 없습니다.")
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "이 위치에 복제"
            panel.message = "이 폴더 안에 ‘\(repoName)’이(가) 복제됩니다."
            guard panel.runModal() == .OK, let parent = panel.url else { return }
            let dest = parent.appendingPathComponent(repoName)
            if FileManager.default.fileExists(atPath: dest.path) {
                self.showSimpleAlert(messageText: "이미 같은 이름의 폴더가 있습니다",
                                     informativeText: "‘\(dest.path)’ 위치에 이미 폴더가 존재합니다.")
                return
            }
            source.folderPath = ""
            source.cloneURL = raw
            source.cloneDestination = dest.path
            let abbrev = (dest.path as NSString).abbreviatingWithTildeInPath
            weakDisplay?.stringValue = "\(raw)\n→ \(abbrev)"
            weakDisplay?.textColor = .labelColor
            weakDisplay?.maximumNumberOfLines = 2
            weakDisplay?.lineBreakMode = .byTruncatingMiddle
        }
        folderButton.target = picker
        folderButton.action = #selector(SourcePickerTarget.folderTapped(_:))
        cloneButton.target = picker
        cloneButton.action = #selector(SourcePickerTarget.cloneTapped(_:))

        _retainedPathPicker = picker

        guard alert.runModal() == .alertFirstButtonReturn else {
            _retainedPathPicker = nil
            _retainedAITrampoline = nil
            return
        }
        _retainedPathPicker = nil

        let aiTool = trampoline.selectedTool()
        let backend = trampoline.selectedBackend()
        let model = trampoline.selectedModel()
        _retainedAITrampoline = nil

        // Resolve final project name + path based on which source mode was used.
        if !source.folderPath.isEmpty {
            let url = URL(fileURLWithPath: source.folderPath)
            let projectName = url.lastPathComponent
            var project = MomentermProject(name: projectName,
                                           path: source.folderPath,
                                           aiTool: aiTool)
            project.localLLMBackend = backend
            project.localLLMModel = model
            MomentermProjectStorage.shared.addProject(project, toSpace: space.id)
            reloadData()
        } else if !source.cloneURL.isEmpty && !source.cloneDestination.isEmpty {
            let dest = URL(fileURLWithPath: source.cloneDestination)
            let projectName = dest.lastPathComponent
            runGitClone(url: source.cloneURL, destination: dest) { [weak self] success, stderr in
                guard let self = self else { return }
                if success {
                    var project = MomentermProject(name: projectName,
                                                   path: dest.path,
                                                   aiTool: aiTool)
                    project.localLLMBackend = backend
                    project.localLLMModel = model
                    MomentermProjectStorage.shared.addProject(project, toSpace: space.id)
                    self.reloadData()
                } else {
                    let detail = stderr?.isEmpty == false ? stderr! : "알 수 없는 오류"
                    self.showSimpleAlert(messageText: "저장소 복제에 실패했습니다",
                                         informativeText: detail)
                }
            }
        } else {
            showSimpleAlert(messageText: "프로젝트 소스를 선택해 주세요",
                            informativeText: "‘폴더 선택’ 또는 ‘저장소 복제’ 중 하나를 사용해 프로젝트 소스를 지정해야 합니다.")
        }
    }

    @objc private func deleteSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? MomentermProjectSpace else { return }
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(space.name)\u{201D} 삭제"
        alert.informativeText = "이 Workspace와 모든 프로젝트 항목이 제거됩니다. 실제 파일은 삭제되지 않습니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var s = MomentermProjectStorage.shared.load()
        s.spaces.removeAll { $0.id == space.id }
        MomentermProjectStorage.shared.save(s)
        reloadData()
    }

    @objc private func deleteProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? MomentermProject else { return }
        let confirm = NSAlert()
        confirm.messageText = "\u{201C}\(project.name)\u{201D}을(를) 삭제하시겠습니까?"
        confirm.informativeText = "삭제된 프로젝트는 복구할 수 없습니다."
        confirm.addButton(withTitle: "삭제")
        confirm.addButton(withTitle: "취소")
        confirm.buttons[0].hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        var s = MomentermProjectStorage.shared.load()
        for i in s.spaces.indices {
            s.spaces[i].projects.removeAll { $0.id == project.id }
        }
        MomentermProjectStorage.shared.save(s)
        reloadData()
    }

    @objc private func copyRecentCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String, !cmd.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }

    @objc private func editProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? MomentermProject else { return }

        var selectedPath: String = project.path

        let nameLabel = NSTextField(labelWithString: "프로젝트 이름")
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = project.name

        let pathLabel = NSTextField(labelWithString: "프로젝트 경로")
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor

        let pathDisplay = NSTextField(labelWithString: project.displayPath)
        pathDisplay.textColor = .labelColor
        pathDisplay.lineBreakMode = .byTruncatingMiddle

        let pathButton = NSButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        pathButton.title = "폴더 선택..."
        pathButton.bezelStyle = .rounded

        let pathRow = NSView()
        pathDisplay.frame = NSRect(x: 0, y: 2, width: 164, height: 20)
        pathButton.frame  = NSRect(x: 168, y: 0, width: 92, height: 24)
        pathRow.addSubview(pathDisplay)
        pathRow.addSubview(pathButton)

        let aiLabel = NSTextField(labelWithString: "AI 도구")
        aiLabel.font = .systemFont(ofSize: 11)
        aiLabel.textColor = .secondaryLabelColor

        let aiPopup = NSPopUpButton()
        aiPopup.addItems(withTitles: AIToolPickerTrampoline.items)
        aiPopup.selectItem(at: AIToolPickerTrampoline.popupIndex(for: project.aiTool))

        let statusLabel = NSTextField(labelWithString: "로컬 LLM 감지 중…")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let modelLabel = NSTextField(labelWithString: "모델")
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor

        let modelPopup = NSPopUpButton()
        modelPopup.addItem(withTitle: "감지 대기 중…")
        modelPopup.isEnabled = false

        let trampoline = AIToolPickerTrampoline(aiPopup: aiPopup, modelPopup: modelPopup, statusLabel: statusLabel)
        _retainedAITrampoline = trampoline
        trampoline.detect(preselectModel: project.localLLMModel)

        let w: CGFloat = 260
        modelPopup.frame  = NSRect(x: 0, y: 0,   width: w, height: 24)
        modelLabel.frame  = NSRect(x: 0, y: 28,  width: w, height: 16)
        statusLabel.frame = NSRect(x: 0, y: 48,  width: w, height: 14)
        aiPopup.frame     = NSRect(x: 0, y: 68,  width: w, height: 24)
        aiLabel.frame     = NSRect(x: 0, y: 96,  width: w, height: 16)
        pathRow.frame     = NSRect(x: 0, y: 120, width: w, height: 24)
        pathLabel.frame   = NSRect(x: 0, y: 148, width: w, height: 16)
        nameField.frame   = NSRect(x: 0, y: 168, width: w, height: 24)
        nameLabel.frame   = NSRect(x: 0, y: 196, width: w, height: 16)

        let stack = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 212))
        stack.addSubview(modelPopup)
        stack.addSubview(modelLabel)
        stack.addSubview(statusLabel)
        stack.addSubview(aiPopup)
        stack.addSubview(aiLabel)
        stack.addSubview(pathRow)
        stack.addSubview(pathLabel)
        stack.addSubview(nameField)
        stack.addSubview(nameLabel)

        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "선택"
        if !project.path.isEmpty {
            openPanel.directoryURL = URL(fileURLWithPath: project.path)
        }

        let pathDisplayRef = pathDisplay
        final class PathPickerTarget: NSObject {
            var handler: () -> Void = {}
            @objc func pick(_ sender: Any) { handler() }
        }
        let picker = PathPickerTarget()
        picker.handler = {
            if openPanel.runModal() == .OK, let url = openPanel.url {
                selectedPath = url.path
                pathDisplayRef.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            }
        }
        pathButton.target = picker
        pathButton.action = #selector(PathPickerTarget.pick(_:))
        _retainedPathPicker = picker

        let alert = NSAlert()
        alert.messageText = "\u{201C}\(project.name)\u{201D} 편집"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else {
            _retainedPathPicker = nil
            _retainedAITrampoline = nil
            return
        }
        _retainedPathPicker = nil

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            _retainedAITrampoline = nil
            return
        }

        let aiTool = trampoline.selectedTool()
        let backend = trampoline.selectedBackend()
        let model = trampoline.selectedModel()
        _retainedAITrampoline = nil

        var s = MomentermProjectStorage.shared.load()
        for i in s.spaces.indices {
            if let j = s.spaces[i].projects.firstIndex(where: { $0.id == project.id }) {
                s.spaces[i].projects[j].name = name
                s.spaces[i].projects[j].path = selectedPath
                s.spaces[i].projects[j].aiTool = aiTool
                s.spaces[i].projects[j].localLLMBackend = backend
                s.spaces[i].projects[j].localLLMModel = model
                break
            }
        }
        MomentermProjectStorage.shared.save(s)
        reloadData()
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? MomentermProjectSpace else { return }

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.stringValue = space.name

        let alert = NSAlert()
        alert.messageText = "\u{201C}\(space.name)\u{201D} 이름 변경"
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
        alert.accessoryView = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != space.name else { return }

        var s = MomentermProjectStorage.shared.load()
        if let i = s.spaces.firstIndex(where: { $0.id == space.id }) {
            s.spaces[i].name = newName
        }
        MomentermProjectStorage.shared.save(s)
        reloadData()
    }

    @objc private func duplicateProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? MomentermProject else { return }
        var s = MomentermProjectStorage.shared.load()
        for i in s.spaces.indices {
            if let j = s.spaces[i].projects.firstIndex(where: { $0.id == project.id }) {
                var copy = project
                copy.id = UUID().uuidString
                copy.name = project.name + " (복사됨)"
                s.spaces[i].projects.insert(copy, at: j + 1)
                break
            }
        }
        MomentermProjectStorage.shared.save(s)
        reloadData()
    }

    @objc private func showFileTree(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? MomentermProject else { return }
        sidebarDelegate?.sidebarDidRequestShowFileTree(path: project.path, projectName: project.name)
    }
}

// MARK: - AI Tool Picker Trampoline

/// Wires the AI tool NSPopUpButton to a local-LLM detection flow.
/// Owns the model picker and status label; updates them as detection completes
/// and as the user changes the AI tool selection.
fileprivate final class AIToolPickerTrampoline: NSObject {
    let aiPopup: NSPopUpButton
    let modelPopup: NSPopUpButton
    let statusLabel: NSTextField
    private var detected: MomentermLocalLLMStatus = .unavailable

    /// Map popup index → tool. Keep this aligned with the popup item order below.
    static let items = ["Claude Code", "Codex", "Gemini", "Local LLM", "없음"]

    init(aiPopup: NSPopUpButton, modelPopup: NSPopUpButton, statusLabel: NSTextField) {
        self.aiPopup = aiPopup
        self.modelPopup = modelPopup
        self.statusLabel = statusLabel
        super.init()
        aiPopup.target = self
        aiPopup.action = #selector(toolChanged(_:))
    }

    @objc func toolChanged(_ sender: Any) { applyEnablement() }

    func applyEnablement() {
        let isLocal = (aiPopup.indexOfSelectedItem == 3)
        modelPopup.isEnabled = isLocal && detected.isAvailable
        if isLocal {
            statusLabel.textColor = detected.isAvailable ? .systemGreen : .systemOrange
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    func detect(preselectModel: String? = nil) {
        statusLabel.stringValue = "로컬 LLM 감지 중…"
        MomentermLocalLLMDetector.detect { [weak self] status in
            guard let self else { return }
            self.detected = status
            self.modelPopup.removeAllItems()
            if status.isAvailable {
                if status.models.isEmpty {
                    self.modelPopup.addItem(withTitle: "(설치된 모델 없음)")
                } else {
                    self.modelPopup.addItems(withTitles: status.models)
                    if let preselect = preselectModel, status.models.contains(preselect) {
                        self.modelPopup.selectItem(withTitle: preselect)
                    }
                }
                self.statusLabel.stringValue = "\(status.backend.displayName) 감지됨 · 모델 \(status.models.count)개"
            } else {
                self.modelPopup.addItem(withTitle: "감지된 LLM 없음")
                self.statusLabel.stringValue = "로컬 LLM 미감지 — Ollama(ollama serve) 또는 LM Studio 실행 필요"
            }
            self.applyEnablement()
        }
    }

    func selectedTool() -> MomentermAITool {
        switch aiPopup.indexOfSelectedItem {
        case 0: return .claudeCode
        case 1: return .codex
        case 2: return .gemini
        case 3: return .localLLM
        default: return .none
        }
    }

    func selectedBackend() -> MomentermLocalLLMBackend? {
        return selectedTool() == .localLLM ? detected.backend : nil
    }

    func selectedModel() -> String? {
        guard selectedTool() == .localLLM, modelPopup.isEnabled,
              let title = modelPopup.titleOfSelectedItem,
              !title.hasPrefix("(") && title != "감지된 LLM 없음" else { return nil }
        return title
    }

    /// Pre-selects popup based on a tool, used by edit form.
    static func popupIndex(for tool: MomentermAITool) -> Int {
        switch tool {
        case .claudeCode, .both: return 0
        case .codex:             return 1
        case .gemini:            return 2
        case .localLLM:          return 3
        case .none:              return 4
        }
    }
}

// MARK: - AI Tool Icon Mapping

private struct AIIconSpec {
    let assetName: String?     // brand PNG in MomentermAssets.xcassets, or nil
    let symbolName: String     // SF Symbol fallback
    let tint: NSColor          // applied only when SF Symbol is used

    static func spec(for tool: MomentermAITool, localBackend: MomentermLocalLLMBackend? = nil) -> AIIconSpec {
        switch tool {
        case .claudeCode:
            return AIIconSpec(assetName: "ai-claude-code",
                              symbolName: "sparkles",
                              tint: .systemOrange)
        case .codex:
            return AIIconSpec(assetName: "ai-codex",
                              symbolName: "chevron.left.slash.chevron.right",
                              tint: .labelColor)
        case .gemini:
            return AIIconSpec(assetName: "ai-gemini",
                              symbolName: "sparkle",
                              tint: .systemBlue)
        case .localLLM:
            switch localBackend {
            case .some(.ollama):
                return AIIconSpec(assetName: "ai-ollama",
                                  symbolName: "cpu",
                                  tint: .systemPurple)
            case .some(.lmStudio):
                return AIIconSpec(assetName: "ai-lmstudio",
                                  symbolName: "cpu",
                                  tint: .systemPurple)
            case .some(.none), nil:
                return AIIconSpec(assetName: nil,
                                  symbolName: "cpu",
                                  tint: .systemPurple)
            }
        case .both:
            return AIIconSpec(assetName: nil,
                              symbolName: "square.stack.3d.up.fill",
                              tint: .controlAccentColor)
        case .none:
            return AIIconSpec(assetName: nil,
                              symbolName: "terminal.fill",
                              tint: .secondaryLabelColor)
        }
    }
}

// MARK: - Workspace creation (Open Folder / Clone Repository)

extension MomentermEmbeddedSidebarVC {

    fileprivate func openFolderAsWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "워크스페이스로 열기"
        panel.message = "워크스페이스로 사용할 폴더를 선택하세요."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard validateAsWorkspace(folderURL: url) else { return }
        createWorkspaceFromFolder(folderURL: url, additionalProject: nil)
    }

    fileprivate func cloneRepositoryAsWorkspace() {
        let urlAlert = NSAlert()
        urlAlert.messageText = "저장소 복제"
        urlAlert.informativeText = "저장소 URL을 입력하거나 원격 소스를 선택하세요."
        urlAlert.addButton(withTitle: "다음")
        urlAlert.addButton(withTitle: "취소")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.placeholderString = "https://github.com/user/repo.git"
        urlAlert.accessoryView = tf
        guard urlAlert.runModal() == .alertFirstButtonReturn else { return }
        let raw = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        guard let repoName = parseRepoName(from: raw) else {
            showSimpleAlert(messageText: "URL을 확인해 주세요",
                            informativeText: "저장소 이름을 추출할 수 없습니다.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "이 위치에 복제"
        panel.message = "이 폴더가 워크스페이스가 되고, 그 안에 ‘\(repoName)’이(가) 복제됩니다."
        guard panel.runModal() == .OK, let parentURL = panel.url else { return }
        guard validateAsWorkspace(folderURL: parentURL) else { return }

        let destination = parentURL.appendingPathComponent(repoName)
        if FileManager.default.fileExists(atPath: destination.path) {
            showSimpleAlert(messageText: "이미 같은 이름의 폴더가 있습니다",
                            informativeText: "‘\(destination.path)’ 위치에 이미 폴더가 존재해 복제할 수 없습니다.")
            return
        }

        runGitClone(url: raw, destination: destination) { [weak self] success, stderr in
            guard let self = self else { return }
            if success {
                let cloned = MomentermProject(name: repoName,
                                              path: destination.path,
                                              aiTool: .claudeCode)
                self.createWorkspaceFromFolder(folderURL: parentURL,
                                               additionalProject: cloned)
            } else {
                let detail = stderr?.isEmpty == false ? stderr! : "알 수 없는 오류"
                self.showSimpleAlert(messageText: "저장소 복제에 실패했습니다",
                                     informativeText: detail)
            }
        }
    }

    fileprivate func validateAsWorkspace(folderURL: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let gitPath = folderURL.appendingPathComponent(".git").path
        let gitignorePath = folderURL.appendingPathComponent(".gitignore").path
        let hasGit = fm.fileExists(atPath: gitPath, isDirectory: &isDir) && isDir.boolValue
        let hasGitignore = fm.fileExists(atPath: gitignorePath)
        if hasGit || hasGitignore {
            showSimpleAlert(messageText: "워크스페이스로 추가할 수 없습니다",
                            informativeText: "프로젝트 파일은 ‘워크스페이스’로 추가할 수 없습니다. 워크스페이스 하위 프로젝트로 생성해 주세요.")
            return false
        }
        return true
    }

    /// Creates a workspace named after `folderURL.lastPathComponent`, then
    /// registers every immediate subfolder as a project. Optionally also adds
    /// `additionalProject` (used by Clone flow when the repo was just cloned).
    fileprivate func createWorkspaceFromFolder(folderURL: URL,
                                               additionalProject: MomentermProject?) {
        let spaceName = folderURL.lastPathComponent
        let space = MomentermProjectStorage.shared.addSpace(named: spaceName)

        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: folderURL,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let subfolders = contents
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for sub in subfolders {
            if let extra = additionalProject,
               (sub.path as NSString).standardizingPath == (extra.path as NSString).standardizingPath {
                continue
            }
            let project = MomentermProject(name: sub.lastPathComponent,
                                           path: sub.path,
                                           aiTool: .claudeCode)
            MomentermProjectStorage.shared.addProject(project, toSpace: space.id)
        }

        if let extra = additionalProject {
            MomentermProjectStorage.shared.addProject(extra, toSpace: space.id)
        }

        reloadData()
        // `reloadData()` → `applyFilter` already expands workspaces; this call
        // is a defensive no-op in case the filter query is non-empty.
        expandAllWorkspaces()
    }

    private func parseRepoName(from urlString: String) -> String? {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let lastSlash = s.lastIndex(of: "/") ?? s.lastIndex(of: ":")
        let name: String
        if let idx = lastSlash {
            name = String(s[s.index(after: idx)...])
        } else {
            name = s
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runGitClone(url: String,
                             destination: URL,
                             completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["clone", url, destination.path]
            let errPipe = Pipe()
            task.standardError = errPipe
            task.standardOutput = Pipe()
            var success = false
            var stderr = ""
            do {
                try task.run()
                task.waitUntilExit()
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                stderr = String(data: data, encoding: .utf8) ?? ""
                success = task.terminationStatus == 0
            } catch {
                stderr = error.localizedDescription
            }
            DispatchQueue.main.async {
                completion(success, success ? nil : stderr)
            }
        }
    }

    private func showSimpleAlert(messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

// MARK: - Inline file-tree mode (per-project file children, header strip, CRUD)

extension MomentermEmbeddedSidebarVC {

    // MARK: Sender → owning project

    /// Resolves the (project, space, rootURL) triple for an action button that
    /// lives inside a project cell.
    private func projectContext(for sender: Any) -> (MomentermProject, MomentermProjectSpace)? {
        guard let view = sender as? NSView else { return nil }
        var v: NSView? = view
        while let cur = v, !(cur is NSTableCellView) { v = cur.superview }
        guard let cell = v else { return nil }
        let row = outlineView.row(for: cell)
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? SidebarItem,
              case .project(let project, let space) = item else { return nil }
        return (project, space)
    }

    // MARK: Inline action handlers

    @objc fileprivate func inlineNewFileTapped(_ sender: Any) {
        guard let (project, _) = projectContext(for: sender) else { return }
        promptCreateInProject(project, isFolder: false)
    }

    @objc fileprivate func inlineNewFolderTapped(_ sender: Any) {
        guard let (project, _) = projectContext(for: sender) else { return }
        promptCreateInProject(project, isFolder: true)
    }

    // Project right-click menu entries (replaces the strip-side buttons in the
    // new layout). Resolved via the NSMenuItem's representedObject rather than
    // by walking the cell tree, since the menu lives outside the table view.
    @objc fileprivate func projectMenuNewFile(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? MomentermProject else { return }
        promptCreateInProject(project, isFolder: false)
    }

    @objc fileprivate func projectMenuNewFolder(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? MomentermProject else { return }
        promptCreateInProject(project, isFolder: true)
    }

    @objc fileprivate func inlineCollapseTapped(_ sender: Any) {
        guard let (project, _) = projectContext(for: sender) else { return }
        toggleInlineFileTree(for: project)
    }

    // MARK: File-node context-menu population (called from menuNeedsUpdate)

    fileprivate func populateFileNodeMenu(_ menu: NSMenu, node: MtFileNode) {
        let rename = NSMenuItem(title: "이름 변경",
                                action: #selector(fileNodeRename(_:)), keyEquivalent: "")
        rename.representedObject = node
        rename.target = self
        menu.addItem(rename)

        let trash = NSMenuItem(title: "휴지통으로 이동",
                               action: #selector(fileNodeTrash(_:)), keyEquivalent: "")
        trash.representedObject = node
        trash.target = self
        menu.addItem(trash)

        if node.isDirectory {
            menu.addItem(NSMenuItem.separator())
            let newFile = NSMenuItem(title: "새 파일…",
                                     action: #selector(fileNodeNewFile(_:)), keyEquivalent: "")
            newFile.representedObject = node
            newFile.target = self
            menu.addItem(newFile)

            let newFolder = NSMenuItem(title: "새 폴더…",
                                       action: #selector(fileNodeNewFolder(_:)), keyEquivalent: "")
            newFolder.representedObject = node
            newFolder.target = self
            menu.addItem(newFolder)
        }
    }

    @objc fileprivate func fileNodeRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode,
              let projectId = projectIdContaining(node: node) else { return }
        promptRename(node, projectId: projectId)
    }

    @objc fileprivate func fileNodeTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode,
              let projectId = projectIdContaining(node: node) else { return }
        confirmAndTrash(node, projectId: projectId)
    }

    @objc fileprivate func fileNodeNewFile(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode,
              node.isDirectory,
              let projectId = projectIdContaining(node: node) else { return }
        promptCreate(in: node.url, isFolder: false, projectId: projectId)
    }

    @objc fileprivate func fileNodeNewFolder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? MtFileNode,
              node.isDirectory,
              let projectId = projectIdContaining(node: node) else { return }
        promptCreate(in: node.url, isFolder: true, projectId: projectId)
    }

    // MARK: Project resolution for file nodes

    /// Returns the project id whose inline tree contains `node`, if any.
    /// Used to scope refresh after a mutation to the right row.
    private func projectIdContaining(node: MtFileNode) -> String? {
        for (projectId, root) in expandedFileTrees {
            if isNode(node, descendantOf: root) { return projectId }
        }
        return nil
    }

    private func isNode(_ node: MtFileNode, descendantOf parent: MtFileNode) -> Bool {
        if node === parent { return true }
        for child in parent.children ?? [] {
            if isNode(node, descendantOf: child) { return true }
        }
        return false
    }

    // MARK: Prompts

    private func promptCreateInProject(_ project: MomentermProject, isFolder: Bool) {
        promptCreate(in: URL(fileURLWithPath: project.path),
                     isFolder: isFolder,
                     projectId: project.id)
    }

    private func promptCreate(in parentDir: URL, isFolder: Bool, projectId: String) {
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
        do {
            let created: URL = try isFolder
                ? MomentermFileOperations.createFolder(in: parentDir, name: field.stringValue)
                : MomentermFileOperations.createFile(in: parentDir, name: field.stringValue)
            refreshInlineTree(forProjectId: projectId, reveal: created)
        } catch {
            presentInlineError(error)
        }
    }

    private func promptRename(_ node: MtFileNode, projectId: String) {
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
            refreshInlineTree(forProjectId: projectId, reveal: newURL)
        } catch {
            presentInlineError(error)
        }
    }

    private func confirmAndTrash(_ node: MtFileNode, projectId: String) {
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
                self.refreshInlineTree(forProjectId: projectId)
            case .failure(let error):
                self.presentInlineError(error)
            }
        }
    }

    private func presentInlineError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    // MARK: Refresh

    /// Re-reads the filesystem for the given project's inline tree while
    /// preserving expansion state, then optionally selects `reveal`.
    private func refreshInlineTree(forProjectId projectId: String, reveal: URL? = nil) {
        guard let root = expandedFileTrees[projectId] else { return }
        let expandedPaths = collectExpandedFilePaths(within: root)
        root.children = nil
        MomentermFileOperations.loadChildren(of: root)
        guard let projectItem = sidebarItem(forProjectId: projectId) else {
            outlineView.reloadData()
            return
        }
        outlineView.reloadItem(projectItem, reloadChildren: true)
        outlineView.expandItem(projectItem)
        reExpandFileTree(root: root, expandedPaths: expandedPaths)
        if let target = reveal { revealFileNode(at: target, in: root) }
    }

    private func collectExpandedFilePaths(within root: MtFileNode) -> Set<String> {
        var paths: Set<String> = []
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? MtFileNode,
                  node.isDirectory,
                  isNode(node, descendantOf: root),
                  outlineView.isItemExpanded(node) else { continue }
            paths.insert(node.url.path)
        }
        return paths
    }

    private func reExpandFileTree(root: MtFileNode, expandedPaths: Set<String>) {
        if root.children == nil { MomentermFileOperations.loadChildren(of: root) }
        for child in root.children ?? [] where child.isDirectory {
            if expandedPaths.contains(child.url.path) {
                outlineView.expandItem(child)
                reExpandFileTree(root: child, expandedPaths: expandedPaths)
            }
        }
    }

    private func revealFileNode(at url: URL, in root: MtFileNode) {
        let rootComps = root.url.standardizedFileURL.pathComponents
        let urlComps = url.standardizedFileURL.pathComponents
        guard urlComps.count > rootComps.count,
              Array(urlComps.prefix(rootComps.count)) == rootComps else { return }
        var current: MtFileNode = root
        for component in urlComps.dropFirst(rootComps.count) {
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
}

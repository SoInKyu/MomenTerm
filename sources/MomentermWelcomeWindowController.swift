//
//  MomentermWelcomeWindowController.swift
//  iTerm2
//
//  Created by MomenTerm on 2026-05-15.
//  Shown at app launch when no project context exists, in place of the
//  default untitled terminal window. Reuses MomentermEmbeddedSidebarVC on
//  the left; the right pane is a static MomentermWelcomeView (no PTY).
//  Selecting a project from the sidebar closes this window and launches a
//  real terminal window in the project directory.
//

import AppKit

@objc final class MomentermWelcomeWindowController: NSWindowController,
                                                    NSWindowDelegate,
                                                    MomentermEmbeddedSidebarDelegate {

    private static var shared: MomentermWelcomeWindowController?

    private let sidebarVC = MomentermEmbeddedSidebarVC()
    private var welcomeView: MomentermWelcomeView?

    @objc static func showSharedWelcome() {
        if shared == nil {
            shared = MomentermWelcomeWindowController()
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    @objc static var hasActiveWelcomeWindow: Bool { shared != nil }

    init() {
        // First-launch size is chosen to match what an iTerm terminal window
        // naturally opens at (160 cols × 50 rows default profile + 220 sidebar
        // + 30 bottom strip + chrome). Keeping welcome and terminal the same
        // size means the transition from welcome → terminal only changes the
        // contents, not the geometry — no jarring resize.
        // Subsequent launches reuse whatever frame the user dragged to via
        // `setFrameAutosaveName` below.
        let initialRect = NSRect(x: 0, y: 0, width: 1280, height: 780)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: initialRect,
                              styleMask: style,
                              backing: .buffered,
                              defer: false)
        window.title = "MomenTerm"
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        // V2: the v1 autosave saved the old 880×540 default. Bumping the name
        // makes existing users adopt the terminal-sized default below; once
        // they resize, the new key persists their preference normally.
        window.setFrameAutosaveName("MomentermWelcomeWindowV2")

        super.init(window: window)

        window.delegate = self
        setupContentView()
        sidebarVC.sidebarDelegate = self
        sidebarVC.suppressProjectOpenDialog = true
        sidebarVC.reloadData()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) not supported")
    }

    private func setupContentView() {
        guard let content = window?.contentView else { return }
        let sidebarWidth: CGFloat = 220
        let w = content.bounds.width
        let h = content.bounds.height

        let sidebar = sidebarVC.view
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: h)
        sidebar.autoresizingMask = [.height, .maxXMargin]
        content.addSubview(sidebar)

        let welcome = MomentermWelcomeView(frame: NSRect(
            x: sidebarWidth, y: 0,
            width: w - sidebarWidth, height: h))
        welcome.autoresizingMask = [.width, .height]
        content.addSubview(welcome)
        welcomeView = welcome
    }

    // MARK: - MomentermEmbeddedSidebarDelegate

    func sidebarDidRequestOpenProject(path: String,
                                      spaceName: String,
                                      projectName: String,
                                      projectId: String,
                                      inNewTab: Bool,
                                      aiCommand: String?) {
        launchProjectTerminal(path: path,
                              spaceName: spaceName,
                              projectName: projectName,
                              projectId: projectId,
                              aiCommand: aiCommand)
    }

    func sidebarDidRequestActivateExistingSession(projectId: String) -> Bool {
        // Welcome window has no live terminal sessions yet.
        return false
    }

    func sidebarDidRequestShowFileTree(path: String, projectName: String) {
        // Welcome state has no host terminal — treat as plain project open.
        let pid = MomentermProjectStorage.shared.load().findProject(atPath: path)?.id ?? ""
        launchProjectTerminal(path: path, spaceName: "",
                              projectName: projectName, projectId: pid, aiCommand: nil)
    }

    func sidebarDidRequestOpenFile(filePath: String,
                                   projectPath: String,
                                   projectName: String) {
        // Same: convert any sub-action into a project-open in a new window.
        let pid = MomentermProjectStorage.shared.load().findProject(atPath: projectPath)?.id ?? ""
        launchProjectTerminal(path: projectPath, spaceName: "",
                              projectName: projectName, projectId: pid, aiCommand: nil)
    }

    // MARK: - Launch real terminal in project directory

    private func launchProjectTerminal(path: String,
                                       spaceName: String,
                                       projectName: String,
                                       projectId: String,
                                       aiCommand: String?) {
        var profile: [AnyHashable: Any] = iTermController.sharedInstance().defaultBookmark() ?? [:]
        profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
        profile[KEY_WORKING_DIRECTORY] = path
        profile[KEY_USE_TAB_COLOR] = NSNumber(value: true)
        profile[KEY_TAB_COLOR] = ITAddressBookMgr.encode(colorForSpaceName(spaceName))
        profile[KEY_ALLOW_TITLE_SETTING] = NSNumber(value: false)
        // Tab title: project (session) name + live job in parens.
        // Bitmask = iTermTitleComponentsSessionName (1) | iTermTitleComponentsJob (2).
        profile[KEY_TITLE_COMPONENTS] = NSNumber(value: 3)
        if !projectName.isEmpty {
            profile[KEY_NAME] = projectName
        }
        if let ai = aiCommand, !ai.isEmpty {
            profile[KEY_INITIAL_TEXT] = ai
        }

        // The user's mental model is "this window is becoming a terminal",
        // not "a new window opens elsewhere". So we capture our own frame,
        // hide ourselves instantly (no fade), and graft that frame onto the
        // new terminal window inside the launcher's didMakeSession callback
        // — which fires synchronously, BEFORE iTerm's async makeKeyAndOrderFront
        // runs. The end result: the terminal appears in the welcome window's
        // exact on-screen slot, so it looks like the window just changed
        // contents rather than being replaced by one in a different space.
        let targetFrame = window?.frame
        window?.orderOut(nil)

        iTermSessionLauncher.launchBookmark(profile,
                                            in: nil,
                                            respectTabbingMode: false) { [weak self] session in
            if let frame = targetFrame,
               let newWindow = session.delegate?.realParentWindow()?.window {
                newWindow.setFrame(frame, display: false, animate: false)
            }
            if !projectId.isEmpty, let guid = session.guid {
                MomentermSessionRegistry.shared.register(sessionGuid: guid, projectId: projectId)
            }
            self?.close()
        }
    }

    private func colorForSpaceName(_ spaceName: String) -> NSColor {
        // Mirrors PseudoTerminal.m it_momentermColorForSpaceName: — single
        // bright fluorescent green for every active tab. The spaceName arg is
        // kept for call-site stability but no longer drives the colour.
        return NSColor(hue: 0.33, saturation: 0.60, brightness: 0.95, alpha: 1.0)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        MomentermWelcomeWindowController.shared = nil
    }
}

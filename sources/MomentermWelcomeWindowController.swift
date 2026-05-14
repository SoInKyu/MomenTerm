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
                                      inNewTab: Bool,
                                      aiCommand: String?) {
        launchProjectTerminal(path: path,
                              spaceName: spaceName,
                              projectName: projectName,
                              aiCommand: aiCommand)
    }

    func sidebarDidRequestShowFileTree(path: String, projectName: String) {
        // Welcome state has no host terminal — treat as plain project open.
        launchProjectTerminal(path: path, spaceName: "",
                              projectName: projectName, aiCommand: nil)
    }

    func sidebarDidRequestOpenFile(filePath: String,
                                   projectPath: String,
                                   projectName: String) {
        // Same: convert any sub-action into a project-open in a new window.
        launchProjectTerminal(path: projectPath, spaceName: "",
                              projectName: projectName, aiCommand: nil)
    }

    // MARK: - Launch real terminal in project directory

    private func launchProjectTerminal(path: String,
                                       spaceName: String,
                                       projectName: String,
                                       aiCommand: String?) {
        var profile: [AnyHashable: Any] = iTermController.sharedInstance().defaultBookmark() ?? [:]
        profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
        profile[KEY_WORKING_DIRECTORY] = path
        profile[KEY_USE_TAB_COLOR] = NSNumber(value: true)
        profile[KEY_TAB_COLOR] = ITAddressBookMgr.encode(colorForSpaceName(spaceName))
        profile[KEY_ALLOW_TITLE_SETTING] = NSNumber(value: false)
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
            self?.close()
        }
    }

    private func colorForSpaceName(_ spaceName: String) -> NSColor {
        if spaceName.isEmpty {
            return NSColor(hue: 0.6, saturation: 0.45, brightness: 0.85, alpha: 1.0)
        }
        let h = (spaceName as NSString).hash
        let hue = CGFloat(h % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1.0)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        MomentermWelcomeWindowController.shared = nil
    }
}

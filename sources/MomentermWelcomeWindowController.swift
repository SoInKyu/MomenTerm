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
        let initialRect = NSRect(x: 0, y: 0, width: 880, height: 540)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: initialRect,
                              styleMask: style,
                              backing: .buffered,
                              defer: false)
        window.title = "MomenTerm"
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.setFrameAutosaveName("MomentermWelcomeWindow")

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

        // Launch the terminal first so the new window is visible before the
        // welcome window disappears — avoids the "blank screen flash" caused
        // by closing first and then opening.
        iTermSessionLauncher.launchBookmark(profile,
                                            in: nil,
                                            respectTabbingMode: false,
                                            completion: nil)
        close()
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

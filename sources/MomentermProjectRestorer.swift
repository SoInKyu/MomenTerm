//
//  MomentermProjectRestorer.swift
//  iTerm2
//
//  Created by MomenTerm on 2026-05-15.
//
//  Captures per-project session state (last AI tool, working directory, command
//  history snapshot) at app quit and restores those sessions on next launch.
//  Driven from iTermApplicationDelegate. Backed by MomentermProjectStorage.
//

import Foundation
import AppKit

@objc final class MomentermProjectRestorer: NSObject {

    /// iTermUserDefaults key. nil/absent → defaults to ON.
    @objc static let autoRestoreUserDefaultsKey = "MomentermAutoRestoreProjects"

    @objc static let shared = MomentermProjectRestorer()

    private override init() {
        super.init()
        // Capture state BEFORE the session is destroyed. Without this, sessions the
        // user closes individually (⌘W) leave no trace because the global app-quit
        // snapshot only sees what's still alive at -applicationWillTerminate:.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWillTerminate(_:)),
            name: NSNotification.Name.iTermSessionWillTerminate,
            object: nil
        )
        // Also opportunistically register pre-existing sessions whose working
        // directory matches a known project. This handles "user already had a
        // terminal open in the project dir before the sidebar opened it".
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive(_:)),
            name: NSNotification.Name("iTermSessionBecameKey"),
            object: nil
        )
    }

    @objc static var autoRestoreEnabled: Bool {
        let ud = iTermUserDefaults.userDefaults()
        if ud.object(forKey: autoRestoreUserDefaultsKey) == nil {
            return true
        }
        return ud.bool(forKey: autoRestoreUserDefaultsKey)
    }

    /// Force initialization so the observers are installed early (called from
    /// -applicationDidFinishLaunching: well before the user closes any tab).
    @objc static func bootstrap() {
        _ = shared
        NSLog("[MomenTerm] MomentermProjectRestorer bootstrapped")
    }

    // MARK: - Capture (app quit)

    /// Called from -applicationWillTerminate:. For every live project-session in the
    /// registry, persist a snapshot into the project record so the next launch can
    /// rehydrate the same workspace.
    @objc func captureAllOnQuit() {
        let registry = MomentermSessionRegistry.shared
        var store = MomentermProjectStorage.shared.load()

        // Clear stale termination flags so projects the user closed manually before
        // quit don't get reopened.
        for si in store.spaces.indices {
            for pi in store.spaces[si].projects.indices {
                store.spaces[si].projects[pi].wasOpenAtTermination = false
            }
        }

        let live = iTermController.sharedInstance().allSessions() ?? []
        // Auto-discover: include sessions whose live cwd matches a known project,
        // even if they were never registered through the sidebar (e.g., opened via
        // ⌘N + manual cd, or revived by iTerm2's own state restoration).
        for session in live {
            guard let guid = session.guid,
                  registry.projectId(forSessionGuid: guid) == nil else { continue }
            let cwd = session.currentLocalWorkingDirectory ?? ""
            guard !cwd.isEmpty,
                  let match = bestProjectMatch(forPath: cwd, in: store) else { continue }
            registry.register(sessionGuid: guid, projectId: match.id)
        }

        let liveByGuid: [String: PTYSession] = Dictionary(
            uniqueKeysWithValues: live.compactMap { session -> (String, PTYSession)? in
                guard let guid = session.guid else { return nil }
                return (guid, session)
            }
        )

        var captured = 0
        for guid in registry.allSessionGuids() {
            guard let projectId = registry.projectId(forSessionGuid: guid),
                  let session = liveByGuid[guid],
                  let idx = store.findProject(withId: projectId) else { continue }
            captureSession(session, into: &store.spaces[idx.spaceIndex].projects[idx.projectIndex])
            captured += 1
        }
        MomentermProjectStorage.shared.save(store)
        NSLog("[MomenTerm] captureAllOnQuit: snapshotted %d project session(s)", captured)
    }

    // MARK: - Incremental capture (per-session, no wasOpenAtTermination flag)

    @objc private func sessionWillTerminate(_ note: Notification) {
        guard let session = note.object as? PTYSession,
              let guid = session.guid,
              let projectId = MomentermSessionRegistry.shared.projectId(forSessionGuid: guid) else { return }
        var store = MomentermProjectStorage.shared.load()
        guard let idx = store.findProject(withId: projectId) else { return }
        // Capture state but DO NOT touch wasOpenAtTermination — the user is closing
        // this session intentionally, so we shouldn't auto-reopen it next launch.
        // We just want to preserve the recent-command list and lastAITool/dir info.
        let wasOpen = store.spaces[idx.spaceIndex].projects[idx.projectIndex].wasOpenAtTermination
        captureSession(session, into: &store.spaces[idx.spaceIndex].projects[idx.projectIndex])
        store.spaces[idx.spaceIndex].projects[idx.projectIndex].wasOpenAtTermination = wasOpen
        MomentermProjectStorage.shared.save(store)
        NSLog("[MomenTerm] incremental capture for project=%@ session=%@", projectId, guid)
    }

    @objc private func sessionDidBecomeActive(_ note: Notification) {
        guard let session = note.object as? PTYSession,
              let guid = session.guid,
              MomentermSessionRegistry.shared.projectId(forSessionGuid: guid) == nil else { return }
        let cwd = session.currentLocalWorkingDirectory ?? ""
        guard !cwd.isEmpty else { return }
        let store = MomentermProjectStorage.shared.load()
        guard let match = bestProjectMatch(forPath: cwd, in: store) else { return }
        MomentermSessionRegistry.shared.register(sessionGuid: guid, projectId: match.id)
        NSLog("[MomenTerm] auto-registered session %@ → project %@ (cwd=%@)", guid, match.id, cwd)
    }

    /// Finds the most specific project (longest path prefix) that contains `path`.
    /// Returns nil if no project's directory is an ancestor of `path`.
    private func bestProjectMatch(forPath path: String, in store: MomentermProjectStore) -> MomentermProject? {
        let resolved = (path as NSString).resolvingSymlinksInPath
        var best: MomentermProject?
        var bestLen = 0
        for project in store.allProjects {
            let p = (project.path as NSString).resolvingSymlinksInPath
            if resolved == p || resolved.hasPrefix(p + "/") {
                if p.count > bestLen {
                    best = project
                    bestLen = p.count
                }
            }
        }
        return best
    }

    // MARK: - Restore (app launch)

    /// Called from -applicationDidFinishLaunching: AFTER iTerm2 has restored its own
    /// windows (if any). For each project marked wasOpenAtTermination, open a new tab
    /// using the saved AI tool. Dedup against any session that's already live (in case
    /// iTerm2's state restoration already revived the same session).
    @objc func restoreIfNeeded() {
        guard Self.autoRestoreEnabled else {
            NSLog("[MomenTerm] restoreIfNeeded: disabled by user default, skipping")
            return
        }
        let store = MomentermProjectStorage.shared.load()
        let candidates = store.allProjects
            .filter { $0.wasOpenAtTermination }
            .sorted { ($0.lastFocusedAt ?? .distantPast) > ($1.lastFocusedAt ?? .distantPast) }
        NSLog("[MomenTerm] restoreIfNeeded: %d candidate(s) to restore", candidates.count)
        guard !candidates.isEmpty else { return }

        // Auto-register any pre-existing sessions that happen to be sitting in a
        // project directory. iTerm2's own restoration may have brought them back
        // without going through our sidebar flow.
        autoRegisterLooseSessions(against: store)

        var opened = 0
        for project in candidates {
            if MomentermSessionRegistry.shared.hasLiveSession(forProjectId: project.id) {
                NSLog("[MomenTerm] restore: project %@ already live, skipping", project.id)
                continue
            }
            openProjectForRestore(project, in: store)
            opened += 1
        }
        NSLog("[MomenTerm] restoreIfNeeded: opened %d new project session(s)", opened)
    }

    // MARK: - private

    private func captureSession(_ session: PTYSession, into project: inout MomentermProject) {
        if let cwd = session.currentLocalWorkingDirectory, !cwd.isEmpty {
            project.lastWorkingDirectory = cwd
        }
        project.lastCommands = latestCommands(for: session, projectPath: project.path, limit: 10)
        project.lastAITool = detectAITool(forSessionGuid: session.guid) ?? project.aiTool
        project.lastFocusedAt = Date()
        project.wasOpenAtTermination = true
    }

    /// Returns up to `limit` most-recent shell-history commands run from a directory
    /// inside the project. Uses the session's currentHost. Empty array when shell
    /// integration is not installed.
    private func latestCommands(for session: PTYSession, projectPath: String, limit: Int) -> [String] {
        let host = session.currentHost
        let uses = iTermShellHistoryController.sharedInstance().commandUses(forHost: host) ?? []
        let resolvedProject = (projectPath as NSString).resolvingSymlinksInPath
        let filtered = uses.filter { use in
            guard let dir = use.directory else { return false }
            let resolvedDir = (dir as NSString).resolvingSymlinksInPath
            return resolvedDir == resolvedProject || resolvedDir.hasPrefix(resolvedProject + "/")
        }
        let sorted = filtered.sorted { a, b in
            (a.time?.doubleValue ?? 0) > (b.time?.doubleValue ?? 0)
        }
        // Reverse to oldest-first so consumers can present them as a chronological log.
        let recent: [String] = sorted.prefix(limit).compactMap { $0.command }
        return Array(recent.reversed())
    }

    private func detectAITool(forSessionGuid guid: String?) -> MomentermAITool? {
        guard let guid = guid else { return nil }
        let monitor = GlobalJobMonitor.instance
        let toolMap: [(String, MomentermAITool)] = [
            ("claude", .claudeCode),
            ("codex",  .codex),
            ("gemini", .gemini),
            ("ollama", .localLLM),
            ("lms",    .localLLM)
        ]
        for (job, tool) in toolMap {
            if monitor.sessionGUIDs(runningJob: job).contains(guid) {
                return tool
            }
        }
        return MomentermAITool.none
    }

    private func autoRegisterLooseSessions(against store: MomentermProjectStore) {
        guard let sessions = iTermController.sharedInstance().allSessions() else { return }
        for session in sessions {
            guard let guid = session.guid,
                  MomentermSessionRegistry.shared.projectId(forSessionGuid: guid) == nil else { continue }
            let cwd = session.currentLocalWorkingDirectory
                ?? (session.profile[KEY_WORKING_DIRECTORY] as? String)
                ?? ""
            guard !cwd.isEmpty,
                  let project = bestProjectMatch(forPath: cwd, in: store) else { continue }
            MomentermSessionRegistry.shared.register(sessionGuid: guid, projectId: project.id)
        }
    }

    private func openProjectForRestore(_ project: MomentermProject, in store: MomentermProjectStore) {
        // Pick the space name so the new tab gets the project's accent color.
        let spaceName = store.spaces.first { $0.projects.contains(where: { $0.id == project.id }) }?.name ?? ""

        // Build the launch command. We honor lastAITool if captured (so a Claude Code
        // session restores into Claude Code even if the project's default AI tool was
        // changed mid-session). Falls back to project.aiLaunchCommand.
        var aiCommand: String?
        if let last = project.lastAITool {
            var p = project
            p.aiTool = last
            aiCommand = p.aiLaunchCommand
        } else {
            aiCommand = project.aiLaunchCommand
        }

        // Effective path: prefer the captured subdirectory so the user lands where
        // they left off. If that directory has been deleted we fall back to project root.
        let cwd: String
        if let lastDir = project.lastWorkingDirectory,
           !lastDir.isEmpty,
           FileManager.default.fileExists(atPath: lastDir) {
            cwd = lastDir
        } else {
            cwd = project.path
        }

        // Route through the same sidebar-delegate flow that handles ordinary "open
        // in new tab" requests: if a terminal already exists, the tab joins it;
        // otherwise a new window is created. The cast to the protocol works because
        // PseudoTerminal conforms to MomentermEmbeddedSidebarDelegate (declared in
        // PseudoTerminal.m).
        if let pt = iTermController.sharedInstance().currentTerminal as? MomentermEmbeddedSidebarDelegate {
            pt.sidebarDidRequestOpenProject(path: cwd,
                                            spaceName: spaceName,
                                            projectName: project.name,
                                            projectId: project.id,
                                            inNewTab: true,
                                            aiCommand: aiCommand)
        } else {
            // No window yet — open a new one. We can't go through the sidebar delegate
            // (it requires an instance), so use the launcher directly.
            launchInNewWindow(project: project, effectiveCWD: cwd, spaceName: spaceName, aiCommand: aiCommand)
        }
    }

    private func launchInNewWindow(project: MomentermProject,
                                   effectiveCWD: String,
                                   spaceName: String,
                                   aiCommand: String?) {
        var profile = iTermController.sharedInstance().defaultBookmark() ?? [:]
        profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
        profile[KEY_WORKING_DIRECTORY] = effectiveCWD
        profile[KEY_NAME] = project.name
        profile[KEY_ALLOW_TITLE_SETTING] = NSNumber(value: false)
        if let cmd = aiCommand, !cmd.isEmpty {
            profile[KEY_INITIAL_TEXT] = cmd
        }
        iTermSessionLauncher.launchBookmark(profile,
                                            in: nil,
                                            respectTabbingMode: false) { session in
            guard let guid = session.guid else { return }
            MomentermSessionRegistry.shared.register(sessionGuid: guid, projectId: project.id)
        }
    }
}

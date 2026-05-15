//
//  MomentermSessionRegistry.swift
//  iTerm2
//
//  Created by MomenTerm on 2026-05-15.
//
//  Maps live PTYSession GUIDs ↔ MomentermProject IDs. Single source of truth for
//  "which sessions belong to which project" while the app is running. Used by
//  single-click activation, active-project highlight, and the termination/restore
//  pipeline to dedup tab creation.
//

import Foundation
import AppKit

@objc final class MomentermSessionRegistry: NSObject {

    @objc static let shared = MomentermSessionRegistry()

    private struct Entry {
        let sessionGuid: String
        let projectId: String
        var lastFocusedAt: Date
    }

    private var entries: [String: Entry] = [:]      // sessionGuid → Entry
    private let lock = NSLock()

    private override init() {
        super.init()
        // PTYSession posts PTYSessionTerminatedNotification when it dies. Auto-clean.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionTerminated(_:)),
            name: NSNotification.Name("PTYSessionTerminatedNotification"),
            object: nil
        )
    }

    @objc private func sessionTerminated(_ note: Notification) {
        // PTYSession is an ObjC class with an NSString *guid property. KVC is stable
        // enough here; avoids importing the whole PTYSession header into Swift.
        guard let sessionObj = note.object as? NSObject,
              let guid = sessionObj.value(forKey: "guid") as? String else {
            return
        }
        unregister(sessionGuid: guid)
    }

    // MARK: - Mutations

    @objc func register(sessionGuid: String, projectId: String) {
        guard !sessionGuid.isEmpty, !projectId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        entries[sessionGuid] = Entry(sessionGuid: sessionGuid,
                                     projectId: projectId,
                                     lastFocusedAt: Date())
    }

    @objc func unregister(sessionGuid: String) {
        guard !sessionGuid.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: sessionGuid)
    }

    @objc func touch(sessionGuid: String) {
        guard !sessionGuid.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if var entry = entries[sessionGuid] {
            entry.lastFocusedAt = Date()
            entries[sessionGuid] = entry
        }
    }

    // MARK: - Queries

    @objc func projectId(forSessionGuid sessionGuid: String) -> String? {
        guard !sessionGuid.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries[sessionGuid]?.projectId
    }

    /// Most recently focused live session GUID for the given project, if any.
    @objc func latestSessionGuid(forProjectId projectId: String) -> String? {
        guard !projectId.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries.values
            .filter { $0.projectId == projectId }
            .max(by: { $0.lastFocusedAt < $1.lastFocusedAt })?
            .sessionGuid
    }

    @objc func hasLiveSession(forProjectId projectId: String) -> Bool {
        return latestSessionGuid(forProjectId: projectId) != nil
    }

    /// Returns all live session GUIDs (regardless of project). Useful for app-quit
    /// snapshot iteration.
    @objc func allSessionGuids() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.keys)
    }

    /// Returns all distinct project IDs that currently have at least one live session.
    @objc func allLiveProjectIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(entries.values.map { $0.projectId }))
    }
}

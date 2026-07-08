//
//  MomentermGitGraphPoller.swift
//  iTerm2
//
//  Async wrapper around `git log --all` for the bottom Git Graph panel.
//  Caches results per cwd, debounces concurrent requests, and posts
//  notifications when a refresh completes so the graph view can redraw
//  without polling itself.
//

import Foundation

@objc final class MomentermGitGraphPoller: NSObject {

    @objc static let shared = MomentermGitGraphPoller()

    /// userInfo["cwd"] = String, userInfo["isGitRepo"] = Bool
    @objc static let didUpdateNotification = Notification.Name("MomentermGitGraphDidUpdate")

    private let queue = DispatchQueue(label: "com.momenterm.gitgraph-poller")
    private var commitsByCwd: [String: [MomentermGitCommit]] = [:]
    private var isGitRepoByCwd: [String: Bool] = [:]
    private var inFlight: Set<String> = []
    private let cacheLock = NSLock()

    private override init() { super.init() }

    // MARK: - Public

    @objc func commitsCount(forCwd cwd: String) -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return commitsByCwd[cwd]?.count ?? 0
    }

    func commits(forCwd cwd: String) -> [MomentermGitCommit] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return commitsByCwd[cwd] ?? []
    }

    @objc func isGitRepo(cwd: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return isGitRepoByCwd[cwd] ?? false
    }

    /// Kick off an async refresh for the given cwd. Skips if the same cwd
    /// is already being refreshed (de-dupe).
    @objc func refresh(cwd: String) {
        guard !cwd.isEmpty else { return }
        cacheLock.lock()
        if inFlight.contains(cwd) {
            cacheLock.unlock()
            return
        }
        inFlight.insert(cwd)
        cacheLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            let (isRepo, commits) = Self.runGitLog(cwd: cwd)
            self.cacheLock.lock()
            self.isGitRepoByCwd[cwd] = isRepo
            self.commitsByCwd[cwd] = commits
            self.inFlight.remove(cwd)
            self.cacheLock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: MomentermGitGraphPoller.didUpdateNotification,
                    object: nil,
                    userInfo: ["cwd": cwd, "isGitRepo": isRepo])
            }
        }
    }

    /// Fetch the full details of one commit (header, message, and diffstat)
    /// asynchronously. The completion runs on the main thread.
    @objc func commitDetail(cwd: String, sha: String, completion: @escaping (String) -> Void) {
        queue.async {
            let text = Self.runGit(cwd: cwd,
                                   arguments: ["show", "--stat", "--format=medium", "--no-color", sha])
            DispatchQueue.main.async {
                completion(text ?? "Unable to load commit details.")
            }
        }
    }

    // MARK: - Implementation

    // 0x1f unit separator keeps fields unambiguous; see MomentermGitLogParser.
    private static let format = "%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s"
    private static let maxCommits = 200

    private static func runGitLog(cwd: String) -> (Bool, [MomentermGitCommit]) {
        guard let text = runGit(cwd: cwd, arguments: [
            "log", "--all", "--topo-order", "--decorate=full",
            "--format=\(format)",
            "-\(maxCommits)"
        ]) else {
            // Not a git repo, no commits, or git not on PATH.
            return (false, [])
        }
        let commits = MomentermGitLogParser.parse(text)
        return (true, commits)
    }

    /// Run git in cwd and return stdout, or nil on launch failure / non-zero exit.
    private static func runGit(cwd: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

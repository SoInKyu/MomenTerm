//
//  MomentermFileOperations.swift
//  iTerm2
//
//  Shared filesystem CRUD + file-node model for the MomenTerm file tree.
//  Used by both the right-side panel (MomentermFileTreeVC) and the inline
//  sidebar tree (MomentermEmbeddedSidebarVC).
//  Rules: no Auto Layout, no fatalError (use it_fatalError when needed).
//

import AppKit

// MARK: - File node model

/// Represents one entry (file or directory) inside the file tree.
/// Used as an `Any` item passed to NSOutlineView — reference identity matters
/// because NSOutlineView caches items by `id` pointer for expand/collapse.
@objc final class MtFileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [MtFileNode]?   // nil = not loaded; [] = loaded, empty

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        super.init()
    }

    var displayName: String { url.lastPathComponent }
}

// MARK: - Filtering

private let kFilteredDirs: Set<String> = [
    "node_modules", ".git", ".svn", ".hg",
    "dist", "build", ".build", "Pods", "DerivedData",
    ".next", ".nuxt", "__pycache__", ".tox", "vendor",
    ".idea", ".vscode", ".expo", "coverage", ".nyc_output"
]

private let kFilteredFileNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]
private let kFilteredExtensions: Set<String> = ["pyc", "o", "class", "a", "dylib", "so"]

enum MtFileFilter {
    static func shouldFilter(url: URL, isDirectory: Bool) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") && isDirectory { return kFilteredDirs.contains(name) }
        if isDirectory { return kFilteredDirs.contains(name) }
        if kFilteredFileNames.contains(name) { return true }
        if name.hasSuffix(".swp") || name.hasSuffix(".swo") { return true }
        return kFilteredExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Operations

enum MomentermFileOperationError: LocalizedError {
    case invalidName
    case alreadyExists(URL)
    case io(Error)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "이름이 비어 있거나 사용할 수 없는 문자를 포함하고 있습니다."
        case .alreadyExists(let url):
            return "\u{201C}\(url.lastPathComponent)\u{201D}이(가) 이미 존재합니다."
        case .io(let underlying):
            return underlying.localizedDescription
        }
    }
}

enum MomentermFileOperations {

    /// Loads (or reloads) the children of `node`. No-op for files. Filtered
    /// using `MtFileFilter`. Directories sort first, then case-insensitive name.
    static func loadChildren(of node: MtFileNode) {
        guard node.isDirectory else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            node.children = []
            return
        }
        var nodes: [MtFileNode] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if MtFileFilter.shouldFilter(url: url, isDirectory: isDir) { continue }
            nodes.append(MtFileNode(url: url, isDirectory: isDir))
        }
        node.children = nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Validates a user-supplied filename. Rejects empty, "." / "..", slashes.
    static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            throw MomentermFileOperationError.invalidName
        }
        if trimmed.contains("/") || trimmed.contains(":") {
            throw MomentermFileOperationError.invalidName
        }
    }

    /// Creates an empty file at `parentDir/name`. Fails if the entry exists.
    @discardableResult
    static func createFile(in parentDir: URL, name: String) throws -> URL {
        try validate(name: name)
        let dest = parentDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw MomentermFileOperationError.alreadyExists(dest)
        }
        do {
            try Data().write(to: dest, options: .withoutOverwriting)
            return dest
        } catch {
            throw MomentermFileOperationError.io(error)
        }
    }

    /// Creates a directory at `parentDir/name`. Fails if the entry exists.
    @discardableResult
    static func createFolder(in parentDir: URL, name: String) throws -> URL {
        try validate(name: name)
        let dest = parentDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw MomentermFileOperationError.alreadyExists(dest)
        }
        do {
            try FileManager.default.createDirectory(at: dest,
                                                    withIntermediateDirectories: false,
                                                    attributes: nil)
            return dest
        } catch {
            throw MomentermFileOperationError.io(error)
        }
    }

    /// Renames `url` to a sibling with `newName`. Returns the new URL.
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        try validate(name: newName)
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        if dest == url { return url }
        if FileManager.default.fileExists(atPath: dest.path) {
            throw MomentermFileOperationError.alreadyExists(dest)
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            throw MomentermFileOperationError.io(error)
        }
    }

    /// Moves `url` to the Trash. Asynchronous; calls `completion` on main queue
    /// with the trashed URL on success.
    static func moveToTrash(_ url: URL,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        NSWorkspace.shared.recycle([url]) { trashed, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(MomentermFileOperationError.io(error)))
                } else if let resulting = trashed[url] {
                    completion(.success(resulting))
                } else {
                    completion(.success(url))
                }
            }
        }
    }
}

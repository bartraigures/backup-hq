import Foundation

/// What a look through a folder leaves alone. A rule is a name pattern (matches a file or folder of that name at any
/// depth, e.g. `node_modules`, `*.tmp`) or, when it contains a slash, a path pattern relative to the folder
/// (e.g. `Build/Products/*`). `*` and `?` work as in the shell; matching ignores case. Lines starting with `#` are comments.
public struct IgnoreRules: Sendable, Equatable {
    /// The standard list: build output, package caches, temp files and the odd system folder. Editable in Settings.
    /// Deliberately not `.git`: a repository's history is often the only copy there is.
    public static let standard: [String] = [
        "# Build output and package caches",
        ".build", "DerivedData", "node_modules", "__pycache__", ".venv", ".gradle", ".cache", "Caches",
        "# Temporary and partial files",
        "*.tmp", "*.part", "*.crdownload", "*.bhq-partial", ".TemporaryItems",
        "# System folders",
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DS_Store", "Thumbs.db",
        "# Lightroom previews and journals (the catalogue itself is kept)",
        "*.lrdata", "*.lrcat-wal", "*.lrcat-journal", "*.lrcat.lock",
    ]

    public let namePatterns: [String]
    public let pathPatterns: [String]

    public init(_ rules: [String]) {
        var names: [String] = [], paths: [String] = []
        for raw in rules {
            var r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.isEmpty || r.hasPrefix("#") { continue }
            while r.hasSuffix("/") { r.removeLast() }
            if r.hasPrefix("/") { r.removeFirst() }
            if r.isEmpty { continue }
            if r.contains("/") { paths.append(r) } else { names.append(r) }
        }
        namePatterns = names
        pathPatterns = paths
    }

    public var isEmpty: Bool { namePatterns.isEmpty && pathPatterns.isEmpty }

    /// A single file or folder name.
    public func matches(name: String) -> Bool {
        namePatterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }

    /// A path relative to the folder: any component matching a name rule, or the whole path matching a path rule.
    public func shouldSkip(relPath: String) -> Bool {
        if !namePatterns.isEmpty {
            for part in relPath.split(separator: "/") where matches(name: String(part)) { return true }
        }
        return pathPatterns.contains { fnmatch($0, relPath, FNM_CASEFOLD) == 0 }
    }
}

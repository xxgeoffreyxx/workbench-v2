import Foundation

public enum PathConfinement {
    /// Canonical path: symlinks resolved for the deepest existing ancestor, `.`/`..` collapsed.
    public static func canonical(_ path: String) -> String {
        let components = lexicalNormalize(path)
        var existing = components
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing) && existing != "/" {
            remainder.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = existing
        if let real = realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        for part in remainder { resolved = (resolved as NSString).appendingPathComponent(part) }
        return lexicalNormalize(resolved)
    }

    /// Collapses `.`, `..` and duplicate slashes without touching the filesystem
    /// (NSString.standardizingPath strips `/private` inconsistently for existing vs missing paths).
    public static func lexicalNormalize(_ path: String) -> String {
        var stack: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !stack.isEmpty { stack.removeLast() }; continue }
            stack.append(String(part))
        }
        return "/" + stack.joined(separator: "/")
    }

    /// Resolves `path` (relative to `root`, or absolute) and returns it only if it stays inside `root`.
    /// Rejects `..` escapes and symlinks pointing out of the root.
    public static func confined(_ path: String, root: URL) -> String? {
        let rootPath = canonical(root.path)
        let joined = path.hasPrefix("/") ? path : (rootPath as NSString).appendingPathComponent(path)
        // Collapse `..` lexically first so `a/../../x` cannot pass through a nonexistent dir.
        let candidate = canonical(joined)
        return isInside(candidate, rootPath) ? candidate : nil
    }

    public static func isInside(_ candidate: String, _ rootPath: String) -> Bool {
        let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidate == rootPath || candidate.hasPrefix(root) || rootPath == "/"
    }
}

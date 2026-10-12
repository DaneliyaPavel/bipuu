import Foundation

/// Where a session's work happens, in project terms.
public struct WorkContext: Hashable, Sendable {
    /// Root directory of the project (the repository, or the directory itself when there is none).
    public var projectRoot: String
    /// The checked-out branch, when there is one.
    public var branch: String?

    public init(projectRoot: String, branch: String? = nil) {
        self.projectRoot = projectRoot; self.branch = branch
    }
}

/// Turns a working directory into a `WorkContext`. A protocol so inference can be tested without a disk.
public protocol WorkContextLocator: Sendable {
    /// `nil` when the directory does not exist.
    func context(forDirectory path: String) -> WorkContext?
}

/// Finds the repository around a directory by reading `.git` and `HEAD` (plain file reads; no
/// process is started, no network, nothing is written).
///
/// - The root is the nearest ancestor holding `.git`. Symlinks are resolved first, so one project is
///   one root however it was reached.
/// - A linked worktree (its `.git` is a file pointing into `<repo>/.git/worktrees/…`) belongs to the
///   main repository: all worktrees of one repository share a project root, and each keeps its own branch.
/// - Submodules are projects of their own.
/// - Outside any repository the directory itself is the root.
public struct GitWorkContextLocator: WorkContextLocator {
    public init() {}

    public func context(forDirectory path: String) -> WorkContext? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard !path.isEmpty, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let start = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var dir = start
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var d: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &d) {
                if d.boolValue {
                    return WorkContext(projectRoot: dir.path, branch: Self.branch(inHead: dotGit.appendingPathComponent("HEAD")))
                }
                if let gitDir = Self.gitDir(fromFile: dotGit, base: dir) {
                    let marker = "/.git/worktrees/"
                    let root = gitDir.path.range(of: marker).map { String(gitDir.path[..<$0.lowerBound]) } ?? dir.path
                    return WorkContext(projectRoot: root, branch: Self.branch(inHead: gitDir.appendingPathComponent("HEAD")))
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return WorkContext(projectRoot: start.path, branch: nil) }
            dir = parent
        }
    }

    /// `gitdir: <path>` (absolute or relative to the directory holding the file).
    private static func gitDir(fromFile file: URL, base: URL) -> URL? {
        guard let text = readSmallFile(file) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(fileURLWithPath: raw, relativeTo: base)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// `ref: refs/heads/<branch>` gives the branch; a detached HEAD gives nil.
    private static func branch(inHead head: URL) -> String? {
        guard let text = readSmallFile(head) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let name = String(line.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    /// The directories we read come from agents, so a repository can be hostile: `.git` or `HEAD` may be a
    /// FIFO (opening it would block), a device, or gigabytes of data. Only a regular file of at most
    /// `maxFileSize` bytes is read, and never more than that.
    public static let maxFileSize = 4_096

    static func readSmallFile(_ url: URL) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maxFileSize,
              let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileSize + 1), data.count <= maxFileSize else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

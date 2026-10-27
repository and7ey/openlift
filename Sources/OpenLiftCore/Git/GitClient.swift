import Foundation

/// One file in `git status --porcelain` output.
///
/// Paths are relative to the repository root, exactly as Git reports them.
public struct GitStatusEntry: Sendable, Hashable {
    public let path: String
    /// Status letter in the index (staged), `nil` when clean.
    public let indexStatus: Character?
    /// Status letter in the working tree (unstaged), `nil` when clean.
    public let workTreeStatus: Character?
    /// Previous path for renames and copies.
    public let originalPath: String?
    /// True for a folder that only appears because something inside it changed.
    public let isAggregate: Bool

    public init(
        path: String,
        indexStatus: Character?,
        workTreeStatus: Character?,
        originalPath: String? = nil,
        isAggregate: Bool = false
    ) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.originalPath = originalPath
        self.isAggregate = isAggregate
    }

    /// A synthetic entry used to flag a folder containing changes.
    public static let directorySummary = GitStatusEntry(
        path: "",
        indexStatus: nil,
        workTreeStatus: nil,
        isAggregate: true
    )

    public var isUntracked: Bool {
        indexStatus == "?" || workTreeStatus == "?"
    }

    public var hasStagedChanges: Bool {
        guard let indexStatus else { return false }
        return indexStatus != " " && indexStatus != "?"
    }

    public var hasUnstagedChanges: Bool {
        guard let workTreeStatus else { return false }
        return workTreeStatus != " " && workTreeStatus != "?"
    }

    /// Unmerged paths use two status letters from a small set, e.g. `UU`.
    public var isConflicted: Bool {
        let letters = [indexStatus, workTreeStatus].compactMap { $0 }
        return letters.contains("U") || (indexStatus == "A" && workTreeStatus == "A")
            || (indexStatus == "D" && workTreeStatus == "D")
    }

    /// The letter shown in the browser, or `nil` for an aggregate folder.
    public var badgeLetter: Character? {
        if isAggregate { return "•" }
        if isConflicted { return "!" }
        if isUntracked { return "?" }
        if let indexStatus, indexStatus != " ", indexStatus != "?" { return indexStatus }
        if let workTreeStatus, workTreeStatus != " ", workTreeStatus != "?" {
            return workTreeStatus
        }
        return nil
    }

    /// Human-readable description used in tooltips.
    public var summary: String {
        if isAggregate { return "Contains changed files" }
        if isConflicted { return "Unmerged conflict" }
        if isUntracked { return "Untracked" }
        var parts: [String] = []
        if hasStagedChanges {
            parts.append(Self.description(for: indexStatus) + " (staged)")
        }
        if hasUnstagedChanges {
            parts.append(Self.description(for: workTreeStatus))
        }
        if let originalPath {
            parts.append("renamed from \(originalPath)")
        }
        return parts.isEmpty ? "Unchanged" : parts.joined(separator: ", ")
    }

    private static func description(for status: Character?) -> String {
        switch status {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        case "U": return "Conflicted"
        case "?": return "Untracked"
        default: return "Changed"
        }
    }
}

/// A point-in-time view of one repository.
public struct GitSnapshot: Sendable {
    public let root: URL
    public let branch: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let entries: [GitStatusEntry]

    /// Entries keyed by their repository-relative path.
    public let entriesByPath: [String: GitStatusEntry]
    /// Folders that contain at least one change below them.
    public let changedDirectories: Set<String>

    public init(
        root: URL,
        branch: String,
        upstream: String?,
        ahead: Int,
        behind: Int,
        entries: [GitStatusEntry]
    ) {
        self.root = root
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
        entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

        var directories: Set<String> = []
        for entry in entries {
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                directories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        changedDirectories = directories
    }

    public var isDirty: Bool { !entries.isEmpty }
    public var changedCount: Int { entries.count }

    /// Status for a repository-relative path; folders roll up their children.
    public func status(forPath path: String) -> GitStatusEntry? {
        if let exact = entriesByPath[path] { return exact }
        return changedDirectories.contains(path) ? .directorySummary : nil
    }

    /// Repository-relative path of a file URL, or `nil` when it is outside.
    public func relativePath(of url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// One-line branch summary for a status bar.
    public var summaryText: String {
        var text = branch
        if ahead > 0 { text += " ↑\(ahead)" }
        if behind > 0 { text += " ↓\(behind)" }
        if entries.isEmpty {
            text += " · clean"
        } else {
            text += " · \(entries.count) changed"
        }
        return text
    }
}

/// Runs the system `git` binary for status and the small set of actions the
/// browser offers. Every call is off the main thread; nothing is cached here.
public enum GitClient {
    public static let executablePath = "/usr/bin/git"

    /// Repository root containing `directory`, or `nil` outside a checkout.
    public static func repositoryRoot(containing directory: URL) async -> URL? {
        guard directory.isFileURL else { return nil }
        return await Task.detached(priority: .utility) {
            let result = try? run(["-C", directory.path, "rev-parse", "--show-toplevel"])
            guard let output = result else { return nil }
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }.value
    }

    public static func snapshot(at root: URL) async throws -> GitSnapshot {
        try await Task.detached(priority: .utility) {
            try snapshotSync(at: root)
        }.value
    }

    public static func stage(_ paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        try await Task.detached(priority: .userInitiated) {
            _ = try run(["-C", root.path, "add", "-A", "--"] + paths)
        }.value
    }

    public static func unstage(_ paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        try await Task.detached(priority: .userInitiated) {
            do {
                _ = try run(["-C", root.path, "reset", "-q", "HEAD", "--"] + paths)
            } catch {
                // A repository without commits has no HEAD to reset to.
                _ = try run(["-C", root.path, "rm", "--cached", "-r", "-q", "--"] + paths)
            }
        }.value
    }

    /// Restores tracked files and removes untracked ones. Destructive.
    public static func discardChanges(_ paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        try await Task.detached(priority: .userInitiated) {
            _ = try run(["-C", root.path, "checkout", "--"] + paths)
            _ = try? run(["-C", root.path, "clean", "-f", "-d", "-q", "--"] + paths)
        }.value
    }

    public static func stageAll(at root: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try run(["-C", root.path, "add", "-A"])
        }.value
    }

    /// Commits the index and returns the short hash.
    @discardableResult
    public static func commit(message: String, at root: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let output = try run(["-C", root.path, "commit", "-m", message])
            let head = try run(["-C", root.path, "rev-parse", "--short", "HEAD"])
            _ = output
            return head.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    public static func recentCommits(at root: URL, limit: Int = 20) async throws -> [GitCommit] {
        try await Task.detached(priority: .utility) {
            let separator = "\u{1F}"
            let output = try run([
                "-C", root.path, "log", "-n", String(limit),
                "--date=short", "--pretty=format:%h\(separator)%an\(separator)%ad\(separator)%s"
            ])
            return output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> GitCommit? in
                    let parts = line.components(separatedBy: separator)
                    guard parts.count >= 4 else { return nil }
                    return GitCommit(
                        hash: parts[0],
                        author: parts[1],
                        date: parts[2],
                        subject: parts[3...].joined(separator: separator)
                    )
                }
        }.value
    }

    // MARK: - Sync work

    private static func snapshotSync(at root: URL) throws -> GitSnapshot {
        let status = try run([
            "-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"
        ])
        let entries = parseStatus(status)

        // `symbolic-ref` names the branch even before the first commit, when
        // `rev-parse --abbrev-ref HEAD` still answers a bare "HEAD".
        var branch = "HEAD"
        if let name = try? run(["-C", root.path, "symbolic-ref", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            branch = name
        } else if let name = try? run(["-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            branch = name
            if name == "HEAD",
               let short = try? run(["-C", root.path, "rev-parse", "--short", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                branch = "detached at \(short)"
            }
        }

        var upstream: String?
        var ahead = 0
        var behind = 0
        if let name = try? run([
            "-C", root.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            upstream = name
            if let counts = try? run([
                "-C", root.path, "rev-list", "--left-right", "--count", "@{u}...HEAD"
            ]).trimmingCharacters(in: .whitespacesAndNewlines) {
                let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if parts.count == 2 {
                    behind = Int(parts[0]) ?? 0
                    ahead = Int(parts[1]) ?? 0
                }
            }
        }

        return GitSnapshot(
            root: root,
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            entries: entries
        )
    }

    /// Parses `git status --porcelain=v1 -z` output.
    public static func parseStatus(_ text: String) -> [GitStatusEntry] {
        let records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }
            let characters = Array(record)
            let indexStatus = characters[0]
            let workTreeStatus = characters[1]
            var path = String(record.dropFirst(3))
            var originalPath: String?

            if indexStatus == "R" || indexStatus == "C"
                || workTreeStatus == "R" || workTreeStatus == "C" {
                if index < records.count {
                    originalPath = records[index]
                    index += 1
                }
            }
            if path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { continue }

            entries.append(
                GitStatusEntry(
                    path: path,
                    indexStatus: indexStatus == " " ? nil : indexStatus,
                    workTreeStatus: workTreeStatus == " " ? nil : workTreeStatus,
                    originalPath: originalPath
                )
            )
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GitError.toolUnavailable(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct GitCommit: Sendable, Hashable {
    public let hash: String
    public let author: String
    public let date: String
    public let subject: String

    public init(hash: String, author: String, date: String, subject: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.subject = subject
    }
}

public enum GitError: Error, LocalizedError {
    case toolUnavailable(String)
    case commandFailed(String)
    case nothingToCommit

    public var errorDescription: String? {
        switch self {
        case .toolUnavailable(let message):
            return "Git is not available: \(message)"
        case .commandFailed(let message):
            return message
        case .nothingToCommit:
            return "There is nothing staged to commit."
        }
    }
}

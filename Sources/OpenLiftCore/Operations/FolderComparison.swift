import Foundation

public struct FolderSnapshot: Sendable, Hashable {
    public let url: URL
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public init(url: URL, relativePath: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.url = url
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public enum FolderDiffStatus: String, Sendable {
    case leftOnly
    case rightOnly
    case different

    public var title: String {
        switch self {
        case .leftOnly: return "Only left"
        case .rightOnly: return "Only right"
        case .different: return "Different"
        }
    }
}

public struct FolderDiffEntry: Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let left: FolderSnapshot?
    public let right: FolderSnapshot?
    public let status: FolderDiffStatus

    public init(
        relativePath: String,
        left: FolderSnapshot?,
        right: FolderSnapshot?,
        status: FolderDiffStatus
    ) {
        self.relativePath = relativePath
        self.left = left
        self.right = right
        self.status = status
    }
}

public struct FolderComparisonResult: Sendable {
    public let leftRoot: URL
    public let rightRoot: URL
    public let entries: [FolderDiffEntry]
    public let sameCount: Int

    public var leftOnlyCount: Int { entries.filter { $0.status == .leftOnly }.count }
    public var rightOnlyCount: Int { entries.filter { $0.status == .rightOnly }.count }
    public var differentCount: Int { entries.filter { $0.status == .different }.count }
}

/// Recursively compares two folders by relative path.
///
/// Directories that exist on both sides are not differences by themselves;
/// their children are. Files compare by size and modification time (within two
/// seconds), which is the fast check a file manager needs before resorting to
/// byte comparison. Package descendants are not walked; a package compares as
/// one item.
public struct FolderComparator: Sendable {
    public init() {}

    public func compare(
        left: URL,
        right: URL,
        includeHidden: Bool = false,
        ignoreDSStore: Bool = true
    ) throws -> FolderComparisonResult {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
            .isPackageKey
        ]

        func snapshot(_ root: URL) throws -> [String: FolderSnapshot] {
            let searchRoot = root.standardizedFileURL
            let rootPrefix = Self.normalized(searchRoot.path) + "/"
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: { _, _ in true }
            ) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
            }

            var result: [String: FolderSnapshot] = [:]
            for case let url as URL in enumerator {
                let path = Self.normalized(url.path)
                guard path.hasPrefix(rootPrefix), path.count > rootPrefix.count else { continue }
                let relative = String(path.dropFirst(rootPrefix.count))
                if ignoreDSStore, url.lastPathComponent == ".DS_Store" { continue }

                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                result[relative] = FolderSnapshot(
                    url: url,
                    relativePath: relative,
                    isDirectory: isDirectory,
                    size: isDirectory ? 0 : Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate
                )
            }
            return result
        }

        let leftItems = try snapshot(left)
        let rightItems = try snapshot(right)
        let unionKeys = Set(leftItems.keys).union(rightItems.keys).sorted()

        var entries: [FolderDiffEntry] = []
        var sameCount = 0

        for path in unionKeys {
            let lhs = leftItems[path]
            let rhs = rightItems[path]
            let status: FolderDiffStatus?
            switch (lhs, rhs) {
            case (let lhs?, let rhs?):
                if lhs.isDirectory, rhs.isDirectory {
                    status = nil
                    sameCount += 1
                } else if lhs.isDirectory != rhs.isDirectory {
                    status = .different
                } else if lhs.size != rhs.size || !Self.sameDate(lhs.modified, rhs.modified) {
                    status = .different
                } else {
                    status = nil
                    sameCount += 1
                }
            case (_?, nil):
                status = .leftOnly
            case (nil, _?):
                status = .rightOnly
            case (nil, nil):
                status = nil
            }
            if let status {
                entries.append(FolderDiffEntry(relativePath: path, left: lhs, right: rhs, status: status))
            }
        }

        return FolderComparisonResult(
            leftRoot: left.standardizedFileURL,
            rightRoot: right.standardizedFileURL,
            entries: entries,
            sameCount: sameCount
        )
    }

    private static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return abs(lhs.timeIntervalSince(rhs)) < 2
        default: return false
        }
    }
}

public struct FolderSyncResult: Sendable {
    public var copied: Int = 0
    public var failures: [(path: String, reason: String)] = []
}

/// Copies the selected comparison entries in one direction, creating missing
/// subdirectories and replacing changed files through a temporary sibling.
public struct FolderSync: Sendable {
    public enum Direction: Sendable, Equatable {
        case leftToRight
        case rightToLeft
    }

    public init() {}

    public func copy(
        _ entries: [FolderDiffEntry],
        direction: Direction,
        leftRoot: URL,
        rightRoot: URL
    ) -> FolderSyncResult {
        var result = FolderSyncResult()
        let manager = FileManager.default

        for entry in entries {
            let source: FolderSnapshot?
            let targetRoot: URL
            switch direction {
            case .leftToRight:
                source = entry.left
                targetRoot = rightRoot
            case .rightToLeft:
                source = entry.right
                targetRoot = leftRoot
            }
            guard let source else { continue }
            let target = targetRoot.appendingPathComponent(entry.relativePath)

            do {
                try manager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if source.isDirectory {
                    try manager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    let staged = target.deletingLastPathComponent()
                        .appendingPathComponent(".openlift-sync-\(UUID().uuidString.prefix(8)).tmp")
                    defer { try? manager.removeItem(at: staged) }
                    try manager.copyItem(at: source.url, to: staged)
                    if manager.fileExists(atPath: target.path) {
                        try manager.removeItem(at: target)
                    }
                    try manager.moveItem(at: staged, to: target)
                }
                result.copied += 1
            } catch {
                result.failures.append((entry.relativePath, error.localizedDescription))
            }
        }
        return result
    }
}

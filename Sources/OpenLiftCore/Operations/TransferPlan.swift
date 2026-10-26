import Foundation

/// One source item paired with the destination it will be written to.
public struct PlannedTransfer: Sendable {
    public let source: URL
    public let target: URL
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    /// Size in bytes; zero for directories that could not be read.
    public let size: Int64
    /// True when a file with this name already existed when the plan was made.
    public let hadConflict: Bool

    public init(
        source: URL,
        target: URL,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: Int64,
        hadConflict: Bool
    ) {
        self.source = source
        self.target = target
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.hadConflict = hadConflict
    }
}

/// A resolved batch: every item already knows its final target name.
///
/// Planning happens before any byte is written so the UI can show an accurate
/// total, ask about conflicts and prepare a single "apply to all" answer.
public struct TransferPlan: Sendable {
    public var entries: [PlannedTransfer] = []
    public var skipped: [URL] = []
    public var conflicts: [URL] = []
    public var totalBytes: Int64 = 0

    public init() {}

    public var itemCount: Int { entries.count }
}

/// Builds a `TransferPlan`, applying the conflict policy for the whole batch
/// or per item when the user answered conflicts individually.
public struct TransferPlanner: Sendable {
    public init() {}

    public func plan(
        sources: [URL],
        to destination: URL,
        kind: TransferKind,
        policy: TransferConflictPolicy,
        policies: [URL: TransferConflictPolicy] = [:]
    ) -> TransferPlan {
        var plan = TransferPlan()
        let manager = FileManager.default

        for source in sources {
            var target = destination.appendingPathComponent(source.lastPathComponent)
            let exists = manager.fileExists(atPath: target.path)
            let effective = policies[source] ?? policy

            if exists {
                plan.conflicts.append(source)
                switch effective {
                case .skip:
                    plan.skipped.append(source)
                    continue
                case .keepBoth:
                    target = FileTransfer.uniqueDestination(for: target)
                case .replace:
                    break
                }
            }

            let isLink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: source.path, isDirectory: &isDirectory)
            let size = Self.byteSize(of: source, isSymbolicLink: isLink)

            plan.entries.append(
                PlannedTransfer(
                    source: source,
                    target: target,
                    isDirectory: isDirectory.boolValue && !isLink,
                    isSymbolicLink: isLink,
                    size: size,
                    hadConflict: exists
                )
            )
            plan.totalBytes += size
        }

        return plan
    }

    private static func byteSize(of url: URL, isSymbolicLink: Bool) -> Int64 {
        guard !isSymbolicLink else { return 0 }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

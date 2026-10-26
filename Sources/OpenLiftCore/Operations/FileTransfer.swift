import Foundation

/// Direction of a file transfer.
public enum TransferKind: Sendable {
    case copy
    case move
}

/// What to do when the destination already contains an item with the same name.
public enum TransferConflictPolicy: Sendable {
    case replace
    case skip
    case keepBoth
}

/// Result of a batch transfer.
public struct TransferOutcome: Sendable {
    public var transferred: [URL] = []
    public var skipped: [URL] = []
    public var failures: [(url: URL, reason: String)] = []
    /// True when the user cancelled: items already finished stay, nothing
    /// partial is left behind.
    public var cancelled = false
    public var copiedBytes: Int64 = 0
    public var totalBytes: Int64 = 0

    public init() {}

    public var isEmpty: Bool {
        transferred.isEmpty && skipped.isEmpty && failures.isEmpty
    }
}

/// Performs copy and move batches with a single conflict policy.
///
/// Planning and execution live in `TransferPlanner` and `TransferExecutor`;
/// this type is the convenient async wrapper the UI calls.
public struct FileTransfer: Sendable {
    public init() {}

    public func transfer(
        _ sources: [URL],
        to destination: URL,
        kind: TransferKind,
        policy: TransferConflictPolicy,
        policies: [URL: TransferConflictPolicy] = [:],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async -> TransferOutcome {
        let plan = plan(sources, to: destination, kind: kind, policy: policy, policies: policies)
        return await Task.detached(priority: .userInitiated) {
            TransferExecutor().execute(plan, kind: kind, isCancelled: isCancelled, progress: progress)
        }.value
    }

    public func plan(
        _ sources: [URL],
        to destination: URL,
        kind: TransferKind,
        policy: TransferConflictPolicy,
        policies: [URL: TransferConflictPolicy] = [:]
    ) -> TransferPlan {
        TransferPlanner().plan(
            sources: sources,
            to: destination,
            kind: kind,
            policy: policy,
            policies: policies
        )
    }

    /// Returns a non-existing `name copy`, `name copy 2`, … URL next to `url`.
    public static func uniqueDestination(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    /// Returns the subset of `sources` whose name already exists in `destination`.
    public static func conflicts(for sources: [URL], in destination: URL) -> [URL] {
        sources.filter { source in
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(source.lastPathComponent).path
            )
        }
    }
}

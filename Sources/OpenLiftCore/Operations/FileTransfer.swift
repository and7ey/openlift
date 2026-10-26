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

    public init() {}
}

/// Performs copy and move batches with a single conflict policy.
///
/// This is the seed of the M2 operation queue: it is already `Sendable` and
/// runs off the main actor, so the UI can call it from a `Task` without
/// blocking. Progress reporting and cancellation land with the queue.
public struct FileTransfer: Sendable {
    public init() {}

    public func transfer(
        _ sources: [URL],
        to destination: URL,
        kind: TransferKind,
        policy: TransferConflictPolicy
    ) async -> TransferOutcome {
        var outcome = TransferOutcome()
        let manager = FileManager.default

        for source in sources {
            let target = destination.appendingPathComponent(source.lastPathComponent)

            do {
                if manager.fileExists(atPath: target.path) {
                    switch policy {
                    case .skip:
                        outcome.skipped.append(source)
                        continue
                    case .replace:
                        try manager.removeItem(at: target)
                    case .keepBoth:
                        let unique = Self.uniqueDestination(for: target)
                        try perform(kind: kind, from: source, to: unique)
                        outcome.transferred.append(unique)
                        continue
                    }
                }
                try perform(kind: kind, from: source, to: target)
                outcome.transferred.append(target)
            } catch {
                outcome.failures.append((source, error.localizedDescription))
            }
        }

        return outcome
    }

    private func perform(kind: TransferKind, from source: URL, to target: URL) throws {
        switch kind {
        case .copy:
            try FileManager.default.copyItem(at: source, to: target)
        case .move:
            try FileManager.default.moveItem(at: source, to: target)
        }
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

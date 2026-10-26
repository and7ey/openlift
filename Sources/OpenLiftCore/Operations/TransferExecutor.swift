import Foundation

/// Executes a `TransferPlan`: copies data, reports progress and honours
/// cancellation.
///
/// Correctness rules:
/// - every destination is written under a hidden temporary name in the target
///   folder and renamed into place only when complete, so a cancelled or
///   failed transfer never leaves a partial file (or a partial tree) visible;
/// - a replaced item is moved aside first and restored if the swap fails, so
///   "replace" cannot lose both versions;
/// - a move stays a single `rename(2)` when source and destination share a
///   volume and falls back to copy-then-delete across volumes;
/// - metadata (permissions, times, ACLs, extended attributes) is copied with
///   `copyfile(3)`, not just the bytes.
public struct TransferExecutor: Sendable {
    public enum MoveStrategy: Sendable {
        /// `rename(2)`, falling back to copy-and-delete on `EXDEV`.
        case automatic
        /// Always copy then delete; used to exercise the cross-volume path.
        case copyAndDelete
    }

    private let moveStrategy: MoveStrategy
    private let chunkSize = 1 << 20

    public init(moveStrategy: MoveStrategy = .automatic) {
        self.moveStrategy = moveStrategy
    }

    public func execute(
        _ plan: TransferPlan,
        kind: TransferKind,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) -> TransferOutcome {
        let session = Session(plan: plan, isCancelled: isCancelled, onProgress: progress)
        session.report(force: true)

        for entry in plan.entries {
            if isCancelled() {
                session.outcome.cancelled = true
                break
            }
            session.currentName = entry.source.lastPathComponent
            do {
                try perform(entry, kind: kind, session: session)
                session.outcome.transferred.append(entry.target)
            } catch TransferError.cancelled {
                session.outcome.cancelled = true
                break
            } catch {
                session.outcome.failures.append((entry.source, error.localizedDescription))
            }
            session.itemsCompleted += 1
            session.report(force: true)
        }

        session.outcome.skipped = plan.skipped
        session.outcome.cancelled = session.outcome.cancelled || isCancelled()
        session.report(force: true, finished: true)
        return session.outcome
    }

    // MARK: - One entry

    private func perform(_ entry: PlannedTransfer, kind: TransferKind, session: Session) throws {
        guard FileManager.default.fileExists(atPath: entry.source.path) else {
            throw TransferError.sourceMissing(entry.source)
        }

        switch kind {
        case .copy:
            try stageCopy(of: entry, session: session)
        case .move:
            try move(entry, session: session)
        }
    }

    private func move(_ entry: PlannedTransfer, session: Session) throws {
        if moveStrategy == .automatic, try renameIntoPlace(entry) {
            return
        }
        try stageCopy(of: entry, session: session)
        try FileManager.default.removeItem(at: entry.source)
    }

    /// Fast path: one atomic `rename(2)`. Returns false only when the volumes
    /// differ (or the filesystem cannot rename), which means copy-and-delete.
    private func renameIntoPlace(_ entry: PlannedTransfer) throws -> Bool {
        let manager = FileManager.default

        if !entry.hadConflict {
            if rename(entry.source.path, entry.target.path) == 0 {
                return true
            }
            let code = errno
            if code == EXDEV || code == ENOTSUP || code == EPERM {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let backup = stagingURL(for: entry.target)
        try manager.moveItem(at: entry.target, to: backup)
        do {
            guard rename(entry.source.path, entry.target.path) == 0 else {
                let code = errno
                try? manager.moveItem(at: backup, to: entry.target)
                if code == EXDEV || code == ENOTSUP || code == EPERM {
                    return false
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try? manager.removeItem(at: backup)
            return true
        } catch {
            try? manager.removeItem(at: backup)
            throw error
        }
    }

    private func stageCopy(of entry: PlannedTransfer, session: Session) throws {
        let manager = FileManager.default
        let staged = stagingURL(for: entry.target)
        try? manager.removeItem(at: staged)

        do {
            try copyTree(entry.source, staged, session: session)
            try commit(staged, to: entry.target)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    /// Moves a finished temporary item into its final name, keeping the old
    /// item until the new one is in place.
    private func commit(_ staged: URL, to target: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: target.path) {
            try manager.moveItem(at: staged, to: target)
            return
        }

        let backup = stagingURL(for: target)
        try manager.moveItem(at: target, to: backup)
        do {
            try manager.moveItem(at: staged, to: target)
            try? manager.removeItem(at: backup)
        } catch {
            try? manager.moveItem(at: backup, to: target)
            throw error
        }
    }

    // MARK: - Tree copy

    private func copyTree(_ source: URL, _ destination: URL, session: Session) throws {
        if session.isCancelled() { throw TransferError.cancelled }

        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let values = try source.resourceValues(forKeys: keys)

        if values.isSymbolicLink == true {
            let linkTarget = try manager.destinationOfSymbolicLink(atPath: source.path)
            try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: linkTarget)
            return
        }

        if values.isDirectory == true {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try manager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            for child in children {
                try copyTree(
                    child,
                    destination.appendingPathComponent(child.lastPathComponent),
                    session: session
                )
            }
            Self.copyMetadata(from: source, to: destination)
            return
        }

        if values.isRegularFile == true {
            try copyFile(source, destination, session: session)
            Self.copyMetadata(from: source, to: destination)
        } else {
            // FIFOs, sockets and devices: let copyfile decide what is possible.
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func copyFile(_ source: URL, _ destination: URL, session: Session) throws {
        let manager = FileManager.default
        manager.createFile(atPath: destination.path, contents: nil)

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        while true {
            if session.isCancelled() { throw TransferError.cancelled }
            let data = try input.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            session.addBytes(Int64(data.count))
            session.report()
        }
    }

    /// Copies permissions, timestamps, ACLs and extended attributes.
    private static func copyMetadata(from source: URL, to destination: URL) {
        _ = copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    // MARK: - Helpers

    /// Hidden sibling name used while an item is being written.
    private func stagingURL(for target: URL) -> URL {
        let directory = target.deletingLastPathComponent()
        return directory.appendingPathComponent(
            ".\(target.lastPathComponent).openlift-\(UUID().uuidString.prefix(8)).tmp"
        )
    }

    // MARK: - Session

    /// Mutable state for one `execute` call. The executor is synchronous and
    /// single-threaded, so no locking is needed here.
    private final class Session {
        let plan: TransferPlan
        let isCancelled: @Sendable () -> Bool
        let onProgress: @Sendable (TransferProgress) -> Void

        var outcome = TransferOutcome()
        var itemsCompleted = 0
        var bytesCompleted: Int64 = 0
        var currentName = ""
        private var lastReport = Date.distantPast
        private var lastReportedBytes: Int64 = 0

        init(
            plan: TransferPlan,
            isCancelled: @escaping @Sendable () -> Bool,
            onProgress: @escaping @Sendable (TransferProgress) -> Void
        ) {
            self.plan = plan
            self.isCancelled = isCancelled
            self.onProgress = onProgress
            outcome.totalBytes = plan.totalBytes
        }

        func addBytes(_ count: Int64) {
            bytesCompleted += count
            outcome.copiedBytes = bytesCompleted
        }

        func report(force: Bool = false, finished: Bool = false) {
            let now = Date()
            if !force {
                let movedBytes = bytesCompleted - lastReportedBytes
                let due = movedBytes >= 4 << 20 || now.timeIntervalSince(lastReport) >= 0.05
                if !due { return }
            }
            lastReport = now
            lastReportedBytes = bytesCompleted
            onProgress(
                TransferProgress(
                    itemsCompleted: itemsCompleted,
                    itemCount: plan.itemCount,
                    bytesCompleted: bytesCompleted,
                    totalBytes: plan.totalBytes,
                    currentName: currentName,
                    finished: finished
                )
            )
        }
    }
}

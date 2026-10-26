import Foundation

/// Cooperative cancellation flag shared between the UI and a running transfer.
///
/// The executor checks it between chunks and between files, so a cancel
/// request takes effect promptly without leaving a half-written file behind:
/// every destination is staged under a temporary name and moved into place
/// only when complete.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Snapshot of a running transfer, delivered on the executor's queue.
public struct TransferProgress: Sendable {
    public var itemsCompleted: Int
    public var itemCount: Int
    public var bytesCompleted: Int64
    public var totalBytes: Int64
    public var currentName: String
    public var finished: Bool

    public init(
        itemsCompleted: Int,
        itemCount: Int,
        bytesCompleted: Int64,
        totalBytes: Int64,
        currentName: String,
        finished: Bool
    ) {
        self.itemsCompleted = itemsCompleted
        self.itemCount = itemCount
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.currentName = currentName
        self.finished = finished
    }

    /// Byte-based when the plan knows the total size, otherwise item-based.
    public var fraction: Double {
        if totalBytes > 0 {
            return min(1, Double(bytesCompleted) / Double(totalBytes))
        }
        guard itemCount > 0 else { return finished ? 1 : 0 }
        return min(1, Double(itemsCompleted) / Double(itemCount))
    }
}

public enum TransferError: Error, LocalizedError {
    case cancelled
    case sourceMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."
        case .sourceMissing(let url):
            return "“\(url.lastPathComponent)” no longer exists."
        }
    }
}

import Foundation

/// What changed in the activity log, so the window can update one row instead
/// of rebuilding the whole table at 20 updates per second.
public enum ActivityChange: Sendable, Equatable {
    case inserted(UUID)
    case updated(UUID)
    case finished(UUID)
    case cleared
}

/// State of one activity entry.
public enum ActivityStatus: String, Sendable, Equatable {
    case running
    case completed
    case cancelled
    case failed
}

/// One line in the activity log: a transfer or an instant file operation.
///
/// Entries are created when an operation starts and updated while it runs,
/// so the Activity window can show live progress and keep the finished history
/// without a separate progress channel.
public struct ActivityEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    /// Where the operation goes; updated as items are processed.
    public var detail: String
    public var status: ActivityStatus
    /// 0…1 while a transfer runs, `nil` for instant operations.
    public var fraction: Double?
    /// Failure description, shown in place of the detail for failed entries.
    public var message: String?
    public let startedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: ActivityStatus = .running,
        fraction: Double? = nil,
        message: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.fraction = fraction
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// True while the operation still expects updates.
    public var isRunning: Bool { status == .running }
}

/// In-memory log of file operations, newest first.
///
/// A single shared instance is enough for one process: the Activity window
/// observes it through `onChange`, and panes append to it as operations run.
/// Nothing is persisted — the log covers the current session.
@MainActor
public final class ActivityLog {
    public static let shared = ActivityLog()

    public private(set) var entries: [ActivityEntry] = []
    /// Called after each change with enough detail for a targeted row update.
    public var onChange: ((ActivityChange) -> Void)?

    /// How many finished entries are kept.
    public var limit = 200

    public init() {}

    /// Starts an entry and returns its identifier for later updates.
    @discardableResult
    public func begin(title: String, detail: String, fraction: Double? = nil) -> UUID {
        let entry = ActivityEntry(title: title, detail: detail, fraction: fraction)
        entries.insert(entry, at: 0)
        trim()
        notify(.inserted(entry.id))
        return entry.id
    }

    /// Updates a running entry, ignoring calls for an entry that is gone.
    public func update(_ id: UUID, detail: String? = nil, fraction: Double? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].isRunning else { return }
        if let detail { entries[index].detail = detail }
        if let fraction { entries[index].fraction = min(1, max(0, fraction)) }
        notify(.updated(id))
    }

    /// Marks an entry finished. Progress is cleared so finished rows stay tidy.
    public func finish(_ id: UUID, status: ActivityStatus, message: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].fraction = nil
        entries[index].message = message
        entries[index].finishedAt = Date()
        notify(.finished(id))
    }

    public func clear() {
        entries.removeAll()
        notify(.cleared)
    }

    public var runningCount: Int {
        entries.filter(\.isRunning).count
    }

    private func trim() {
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    private func notify(_ change: ActivityChange) {
        onChange?(change)
    }
}

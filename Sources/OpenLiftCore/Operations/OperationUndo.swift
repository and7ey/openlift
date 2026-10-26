import Foundation

/// Applies a `FileOperationRecord` forwards or backwards.
///
/// `perform(_:forward:)` always returns the record that describes the action it
/// just performed, so callers can store it for the opposite direction:
///
/// - copying forwards returns the copy record; reversing it trashes the copies
///   and returns that trash record;
/// - reversing a trash is a move out of the Trash, so it returns a move record;
/// - reversing a move simply returns the opposite move.
///
/// Because every inverse is itself one of the record kinds, undo and redo both
/// run `perform(record, forward: false)` on the record they pop: reversing a
/// stored action always moves one step in the direction the user asked for.
public struct OperationUndo: Sendable {
    public init() {}

    public func perform(_ record: FileOperationRecord, forward: Bool) async throws -> FileOperationRecord {
        switch record.kind {
        case .copy:
            return try await (forward ? copy(record) : trashTargets(of: record))

        case .move, .rename:
            let pairs = forward
                ? record.pairs
                : record.pairs.map { FileOperationRecord.Pair(source: $0.target, target: $0.source) }
            for pair in pairs {
                try moveItem(from: pair.source, to: pair.target)
            }
            return FileOperationRecord(kind: record.kind, pairs: pairs)

        case .trash:
            return try await (forward ? trashSources(of: record) : restore(record))

        case .createDirectory:
            if forward {
                for pair in record.pairs where !FileManager.default.fileExists(atPath: pair.source.path) {
                    try FileManager.default.createDirectory(at: pair.source, withIntermediateDirectories: false)
                }
                return record
            }
            return try await trashSources(of: record)
        }
    }

    // MARK: - Steps

    private func copy(_ record: FileOperationRecord) throws -> FileOperationRecord {
        for pair in record.pairs where !FileManager.default.fileExists(atPath: pair.target.path) {
            try FileManager.default.copyItem(at: pair.source, to: pair.target)
        }
        return record
    }

    private func moveItem(from source: URL, to target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        try FileManager.default.moveItem(at: source, to: target)
    }

    private func trashTargets(of record: FileOperationRecord) async throws -> FileOperationRecord {
        var trashed: [FileOperationRecord.Pair] = []
        for pair in record.pairs {
            let url = try await LocalFileProvider().trash(pair.target)
            trashed.append(.init(source: pair.target, target: url))
        }
        return FileOperationRecord(kind: .trash, pairs: trashed)
    }

    private func trashSources(of record: FileOperationRecord) async throws -> FileOperationRecord {
        var trashed: [FileOperationRecord.Pair] = []
        for pair in record.pairs {
            let url = try await LocalFileProvider().trash(pair.source)
            trashed.append(.init(source: pair.source, target: url))
        }
        return FileOperationRecord(kind: .trash, pairs: trashed)
    }

    /// A restore is a move out of the Trash, so it is recorded as one.
    private func restore(_ record: FileOperationRecord) throws -> FileOperationRecord {
        var restored: [FileOperationRecord.Pair] = []
        for pair in record.pairs {
            try moveItem(from: pair.target, to: pair.source)
            restored.append(.init(source: pair.target, target: pair.source))
        }
        return FileOperationRecord(kind: .move, pairs: restored)
    }
}

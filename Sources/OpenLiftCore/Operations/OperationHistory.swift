import Foundation

/// Undo and redo stacks for file operations.
///
/// The stacks are managed here rather than through `UndoManager` because
/// undoing a transfer is asynchronous: `UndoManager` only accepts the matching
/// redo registration while its synchronous undo handler is running, which an
/// `await` cannot satisfy. Two plain stacks keep the model obvious.
@MainActor
public final class OperationHistory {
    private var undoStack: [FileOperationRecord] = []
    private var redoStack: [FileOperationRecord] = []
    private let performer = OperationUndo()
    private var isBusy = false

    /// How many steps are remembered before the oldest is dropped.
    public var limit = 50

    public var onChange: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public init() {}

    public var canUndo: Bool { !isBusy && !undoStack.isEmpty }
    public var canRedo: Bool { !isBusy && !redoStack.isEmpty }
    public var undoTitle: String { undoStack.last.map { "Undo \($0.title)" } ?? "Undo" }
    public var redoTitle: String { redoStack.last.map { "Redo \($0.title)" } ?? "Redo" }

    /// Remembers a finished operation. Any new operation clears the redo stack.
    public func record(_ record: FileOperationRecord) {
        guard !record.pairs.isEmpty, !isBusy else { return }
        undoStack.append(record)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
        onChange?()
    }

    public func undo() { step(forward: false) }

    public func redo() { step(forward: true) }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        onChange?()
    }

    private func step(forward: Bool) {
        guard !isBusy else { return }
        let record: FileOperationRecord?
        if forward {
            record = redoStack.popLast()
        } else {
            record = undoStack.popLast()
        }
        guard let record else { return }

        isBusy = true
        onChange?()

        Task {
            do {
                // Every record is stored in the direction opposite to the one
                // it will be applied in: it is either an inverse produced by a
                // previous undo, or the operation itself. Applying it backwards
                // therefore always moves one step in the direction the user
                // asked for, and the result is the inverse for the other stack.
                let result = try await performer.perform(record, forward: false)
                if forward {
                    undoStack.append(result)
                } else {
                    redoStack.append(result)
                }
            } catch {
                // The step did not complete: put it back where it came from.
                if forward {
                    redoStack.append(record)
                } else {
                    undoStack.append(record)
                }
                onError?(error)
            }
            isBusy = false
            onChange?()
        }
    }
}

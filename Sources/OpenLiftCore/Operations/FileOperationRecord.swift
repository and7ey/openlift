import Foundation

/// What a finished file operation did, in a form that can be undone later.
///
/// Every record stores source/target pairs so the inverse operation never has
/// to guess names: a move knows both ends, a copy knows what it created, and a
/// trashed item knows where it went.
public struct FileOperationRecord: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case copy
        case move
        case rename
        case trash
        case createDirectory
    }

    public struct Pair: Sendable, Equatable {
        public let source: URL
        public let target: URL

        public init(source: URL, target: URL) {
            self.source = source
            self.target = target
        }
    }

    public let kind: Kind
    public let pairs: [Pair]

    public init(kind: Kind, pairs: [Pair]) {
        self.kind = kind
        self.pairs = pairs
    }

    /// Menu wording, e.g. `Copy “photo.jpg”` or `Move 3 items`.
    public var title: String {
        switch kind {
        case .copy: return Self.title(verb: "Copy", pairs: pairs)
        case .move: return Self.title(verb: "Move", pairs: pairs)
        case .rename: return Self.title(verb: "Rename", pairs: pairs)
        case .trash: return Self.title(verb: "Move to Trash", pairs: pairs)
        case .createDirectory: return "New Folder"
        }
    }

    private static func title(verb: String, pairs: [Pair]) -> String {
        guard let first = pairs.first else { return verb }
        if pairs.count == 1 {
            return "\(verb) “\(first.source.lastPathComponent)”"
        }
        return "\(verb) \(pairs.count) items"
    }
}

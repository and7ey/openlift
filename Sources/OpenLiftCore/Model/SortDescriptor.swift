import Foundation

/// Sort keys exposed by the browser. Mirrors a useful subset of common
/// file-manager
/// column registry; more keys can be added without touching the UI.
public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name
    case kind
    case size
    case modified
    case created

    public var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        }
    }
}

/// How a directory listing is sorted.
public struct SortDescriptor: Codable, Equatable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: SortKey = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    public static let `default` = SortDescriptor()
}

/// How a directory listing is grouped.
public enum GroupKey: String, Codable, CaseIterable, Sendable {
    case none
    case kind
    case name

    public var title: String {
        switch self {
        case .none: return "None"
        case .kind: return "Kind"
        case .name: return "Name"
        }
    }
}

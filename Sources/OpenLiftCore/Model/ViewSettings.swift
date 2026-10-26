import Foundation

/// Per-pane display preferences. Persisted with the window state so a pane
/// reopens exactly as the user left it.
public struct ViewSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case list
        case icon

        public var title: String {
            switch self {
            case .list: return "as List"
            case .icon: return "as Icons"
            }
        }
    }

    public var mode: Mode
    public var sort: SortDescriptor
    public var group: GroupKey
    public var showHidden: Bool
    public var showPathBar: Bool
    public var showStatusBar: Bool

    public init(
        mode: Mode = .list,
        sort: SortDescriptor = .default,
        group: GroupKey = .none,
        showHidden: Bool = false,
        showPathBar: Bool = true,
        showStatusBar: Bool = true
    ) {
        self.mode = mode
        self.sort = sort
        self.group = group
        self.showHidden = showHidden
        self.showPathBar = showPathBar
        self.showStatusBar = showStatusBar
    }

    public static let `default` = ViewSettings()
}

/// Options passed to a provider when listing a directory.
public struct ListOptions: Sendable {
    public var showHidden: Bool
    public var recursive: Bool

    public init(showHidden: Bool = false, recursive: Bool = false) {
        self.showHidden = showHidden
        self.recursive = recursive
    }
}

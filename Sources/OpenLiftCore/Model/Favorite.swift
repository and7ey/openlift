import Foundation

/// Sidebar entry. Favorites are a tree: a group can contain groups and paths.
public struct Favorite: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A folder the user pinned.
        case path
        /// A user-created group of favorites.
        case group
        /// A mounted volume or well-known location provided by the system.
        case smart
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    /// Absolute path for `.path` entries; `nil` for groups.
    public var path: String?
    /// SF Symbol name.
    public var symbol: String?
    public var children: [Favorite]?

    public init(
        id: UUID = UUID(),
        kind: Kind = .path,
        name: String,
        path: String? = nil,
        symbol: String? = nil,
        children: [Favorite]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.symbol = symbol
        self.children = children
    }

    public var url: URL? {
        path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public var isExpandable: Bool {
        kind == .group || !(children?.isEmpty ?? true)
    }
}

public extension Favorite {
    /// Default sidebar shown on first launch.
    ///
    /// IDs are fixed so the tree compares equal across calls and the outline
    /// view can keep expansion state between reloads.
    static var defaults: [Favorite] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func id(_ value: String) -> UUID { UUID(uuidString: value)! }

        return [
            Favorite(id: id("00000000-0000-0000-0000-00000000F001"), kind: .group, name: "Favorites", symbol: "star", children: [
                Favorite(id: id("00000000-0000-0000-0000-00000000F002"), name: "Home", path: home, symbol: "house"),
                Favorite(id: id("00000000-0000-0000-0000-00000000F003"), name: "Desktop", path: home + "/Desktop", symbol: "menubar.dock.rectangle"),
                Favorite(id: id("00000000-0000-0000-0000-00000000F004"), name: "Documents", path: home + "/Documents", symbol: "doc"),
                Favorite(id: id("00000000-0000-0000-0000-00000000F005"), name: "Downloads", path: home + "/Downloads", symbol: "arrow.down.circle"),
                Favorite(id: id("00000000-0000-0000-0000-00000000F006"), name: "Applications", path: "/Applications", symbol: "square.grid.2x2")
            ]),
            Favorite(id: id("00000000-0000-0000-0000-00000000F007"), kind: .smart, name: "Locations", symbol: "externaldrive", children: [
                Favorite(id: id("00000000-0000-0000-0000-00000000F008"), name: "Macintosh HD", path: "/", symbol: "internaldrive")
            ])
        ]
    }
}

/// Sidebar row type after flattening a favorite tree for the outline view.
public struct FavoriteRow: Identifiable, Hashable, Sendable {
    public var id: UUID { favorite.id }
    public let favorite: Favorite
    public let depth: Int

    public init(favorite: Favorite, depth: Int) {
        self.favorite = favorite
        self.depth = depth
    }

    public static func flatten(_ favorites: [Favorite], depth: Int = 0) -> [FavoriteRow] {
        favorites.flatMap { favorite -> [FavoriteRow] in
            var rows = [FavoriteRow(favorite: favorite, depth: depth)]
            if let children = favorite.children {
                rows.append(contentsOf: flatten(children, depth: depth + 1))
            }
            return rows
        }
    }
}

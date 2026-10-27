import Foundation

/// A saved server address. Passwords are deliberately not part of bookmarks.
public struct RemoteBookmark: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var proto: RemoteProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var path: String
    /// SSH key used by SFTP. A file path, never a secret.
    public var identityFile: String?

    public init(
        id: UUID = UUID(),
        name: String,
        proto: RemoteProtocol,
        host: String,
        port: Int,
        username: String,
        path: String,
        identityFile: String? = nil
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port
        self.username = username
        self.path = path
        self.identityFile = identityFile
    }

    public init(connection: RemoteConnection) {
        let label = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        self.init(
            name: "\(connection.proto.title) · \(label)",
            proto: connection.proto,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            path: connection.path,
            identityFile: connection.identityFile
        )
    }

    /// Recreates a connection without a password; the connect sheet asks for
    /// one (or uses the SSH agent when left empty).
    public var connection: RemoteConnection {
        RemoteConnection(
            proto: proto,
            host: host,
            port: port,
            username: username,
            password: "",
            identityFile: identityFile,
            path: path
        )
    }
}

/// Persists saved servers in `UserDefaults`; never stores credentials.
public final class RemoteBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let queue = DispatchQueue(label: "dev.openlift.remote-bookmarks")

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "OpenLift.remoteBookmarks"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> [RemoteBookmark] {
        queue.sync {
            guard let data = defaults.data(forKey: storageKey),
                  let bookmarks = try? JSONDecoder().decode([RemoteBookmark].self, from: data) else {
                return []
            }
            return bookmarks
        }
    }

    /// Adds a bookmark, replacing an existing one for the same server/path.
    public func add(_ bookmark: RemoteBookmark) {
        queue.sync {
            var bookmarks = loadUnsafe()
            bookmarks.removeAll {
                $0.proto == bookmark.proto
                    && $0.host.caseInsensitiveCompare(bookmark.host) == .orderedSame
                    && $0.port == bookmark.port
                    && $0.username == bookmark.username
                    && $0.path == bookmark.path
            }
            bookmarks.append(bookmark)
            saveUnsafe(bookmarks)
        }
    }

    public func remove(_ id: UUID) {
        queue.sync {
            var bookmarks = loadUnsafe()
            bookmarks.removeAll { $0.id == id }
            saveUnsafe(bookmarks)
        }
    }

    public func removeAll() {
        queue.sync {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func loadUnsafe() -> [RemoteBookmark] {
        guard let data = defaults.data(forKey: storageKey),
              let bookmarks = try? JSONDecoder().decode([RemoteBookmark].self, from: data) else {
            return []
        }
        return bookmarks
    }

    private func saveUnsafe(_ bookmarks: [RemoteBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

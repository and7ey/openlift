import Foundation

/// Application support locations.
public enum AppPaths {
    public static let bundleIdentifier = "dev.openlift.OpenLift"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("OpenLift", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var favoritesFile: URL {
        supportDirectory.appendingPathComponent("favorites.json")
    }

    public static var windowStateFile: URL {
        supportDirectory.appendingPathComponent("window-state.json")
    }
}

/// Persists the sidebar favorite tree as JSON.
///
/// Commercial managers often store favorites in a Core Data blob; a plain
/// `Codable` document is
/// enough for the MVP and keeps migrations trivial.
public final class FavoritesStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.openlift.favorites")

    public init(fileURL: URL = AppPaths.favoritesFile) {
        self.fileURL = fileURL
    }

    /// Loads favorites, falling back to the default tree when the file is
    /// missing or unreadable.
    public func load() -> [Favorite] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else {
                return Favorite.defaults
            }
            guard let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else {
                return Favorite.defaults
            }
            return decoded
        }
    }

    public func save(_ favorites: [Favorite]) {
        queue.sync {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(favorites)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("OpenLift: failed to save favorites — \(error.localizedDescription)")
            }
        }
    }
}

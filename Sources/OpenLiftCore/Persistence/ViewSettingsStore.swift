import Foundation

/// Remembers view settings per folder.
///
/// Finder and other file managers let a folder keep its own sort mode, view mode and
/// hidden-file preference. Settings are stored as one JSON document in
/// `UserDefaults`, keyed by absolute path.
public final class ViewSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let queue = DispatchQueue(label: "dev.openlift.view-settings")

    public init(defaults: UserDefaults = .standard, storageKey: String = "OpenLift.viewSettingsByPath") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func settings(for path: String) -> ViewSettings? {
        queue.sync {
            loadMap()[path]
        }
    }

    public func set(_ settings: ViewSettings, for path: String) {
        queue.sync {
            var map = loadMap()
            map[path] = settings
            save(map)
        }
    }

    public func remove(for path: String) {
        queue.sync {
            var map = loadMap()
            map.removeValue(forKey: path)
            save(map)
        }
    }

    public func removeAll() {
        queue.sync {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func loadMap() -> [String: ViewSettings] {
        guard let data = defaults.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: ViewSettings].self, from: data) else {
            return [:]
        }
        return map
    }

    private func save(_ map: [String: ViewSettings]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

import Foundation

/// App-level preferences that are not tied to one folder.
public struct AppSettings: Codable, Sendable, Equatable {
    /// How many undo steps and activity entries to keep.
    public var undoLimit: Int
    public var activityLimit: Int

    public init(undoLimit: Int = 50, activityLimit: Int = 200) {
        self.undoLimit = undoLimit
        self.activityLimit = activityLimit
    }
}

/// Persists `AppSettings` as JSON in `UserDefaults`.
@MainActor
public final class AppSettingsStore {
    public static let shared = AppSettingsStore()

    public private(set) var settings: AppSettings
    public var onChange: ((AppSettings) -> Void)?

    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "OpenLift.appSettings") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = stored
        } else {
            settings = AppSettings()
        }
    }

    public func update(_ settings: AppSettings) {
        self.settings = settings
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: storageKey)
        }
        onChange?(settings)
    }
}

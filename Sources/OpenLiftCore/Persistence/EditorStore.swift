import Foundation

/// Remembers which application “Edit” opens files with.
///
/// The default is TextEdit; a custom application is stored by path only.
@MainActor
public final class EditorStore {
    public static let shared = EditorStore()

    public private(set) var applicationPath: String?
    public var onChange: ((String) -> Void)?

    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "OpenLift.editorPath") {
        self.defaults = defaults
        self.storageKey = storageKey
        applicationPath = defaults.string(forKey: storageKey)
    }

    /// The configured editor, or TextEdit when nothing valid is set.
    public var resolvedApplicationPath: String {
        if let applicationPath, FileManager.default.fileExists(atPath: applicationPath) {
            return applicationPath
        }
        return Self.defaultApplicationPath
    }

    public var displayName: String {
        let name = (resolvedApplicationPath as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    public var isCustomized: Bool {
        guard let applicationPath, !applicationPath.isEmpty else { return false }
        return applicationPath != Self.defaultApplicationPath
    }

    public static var defaultApplicationPath: String {
        let candidates = [
            "/System/Applications/TextEdit.app",
            "/Applications/TextEdit.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    public func setApplicationPath(_ path: String?) {
        let cleaned = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (cleaned?.isEmpty ?? true) ? nil : cleaned
        applicationPath = value
        if let value {
            defaults.set(value, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
        onChange?(resolvedApplicationPath)
    }

    public func resetToDefault() {
        setApplicationPath(nil)
    }
}

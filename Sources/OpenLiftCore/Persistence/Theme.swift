import Foundation

/// Appearance a theme asks AppKit to use for its windows.
public enum ThemeAppearance: String, Codable, Hashable, Sendable {
    case system
    case light
    case dark
}

/// A color scheme for the file browser.
///
/// A theme only describes the list canvas: the appearance AppKit should use,
/// the row background, the alternating tint and the selection fill. Missing
/// colors mean “use the system default”, which is what the System theme does.
public struct Theme: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    /// Row background as `RRGGBB`, or `nil` for the system color.
    public let background: String?
    /// Alternating row tint as `RRGGBB`, or `nil` to disable it.
    public let alternateBackground: String?
    /// Selected row fill as `RRGGBB`, or `nil` for the system accent.
    public let selection: String?
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        appearance: ThemeAppearance,
        background: String? = nil,
        alternateBackground: String? = nil,
        selection: String? = nil,
        isBuiltIn: Bool = true
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.background = background
        self.alternateBackground = alternateBackground
        self.selection = selection
        self.isBuiltIn = isBuiltIn
    }

    public static let system = Theme(
        id: "system",
        name: "System",
        appearance: .system
    )

    public static let graphite = Theme(
        id: "graphite",
        name: "Graphite",
        appearance: .dark,
        background: "1E1F22",
        alternateBackground: "242529",
        selection: "3B3D42"
    )

    public static let nord = Theme(
        id: "nord",
        name: "Nord",
        appearance: .dark,
        background: "2E3440",
        alternateBackground: "343B49",
        selection: "4C566A"
    )

    public static let solarizedLight = Theme(
        id: "solarized-light",
        name: "Solarized Light",
        appearance: .light,
        background: "FDF6E3",
        alternateBackground: "F7F1DE",
        selection: "E4DCC3"
    )

    public static let solarizedDark = Theme(
        id: "solarized-dark",
        name: "Solarized Dark",
        appearance: .dark,
        background: "002B36",
        alternateBackground: "073642",
        selection: "0E4B5A"
    )

    public static let builtIn: [Theme] = [
        .system,
        .graphite,
        .nord,
        .solarizedLight,
        .solarizedDark
    ]

    public static func theme(withID id: String) -> Theme? {
        builtIn.first { $0.id == id }
    }
}

/// Remembers the selected theme in `UserDefaults`.
///
/// Only the identifier is stored, so new built-in themes appear without a
/// migration and an unknown identifier falls back to the System theme.
@MainActor
public final class ThemeStore {
    public static let shared = ThemeStore()

    public private(set) var current: Theme
    public var onChange: ((Theme) -> Void)?

    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "OpenLift.themeIdentifier") {
        self.defaults = defaults
        self.storageKey = storageKey
        let stored = defaults.string(forKey: storageKey)
        current = stored.flatMap(Theme.theme(withID:)) ?? .system
    }

    public func select(_ theme: Theme) {
        guard theme.id != current.id else { return }
        current = theme
        defaults.set(theme.id, forKey: storageKey)
        onChange?(theme)
    }

    /// Re-reads the stored identifier, e.g. after another window changed it.
    public func reload() {
        let stored = defaults.string(forKey: storageKey)
        current = stored.flatMap(Theme.theme(withID:)) ?? .system
    }
}

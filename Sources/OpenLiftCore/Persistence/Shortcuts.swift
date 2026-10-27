import Foundation

/// Modifier flags that survive `Codable` without importing AppKit in Core.
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// One menu key equivalent: the key string AppKit expects plus modifiers.
///
/// `key` uses the same spelling as `NSMenuItem.keyEquivalent`: a lowercase
/// character, `"\r"` for Return, `"\u{8}"` for Delete, and so on.
public struct KeyboardShortcut: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Function-key spellings accepted by `NSMenuItem.keyEquivalent`.
public enum ShortcutKey {
    public static let f1 = "\u{F704}"
    public static let f2 = "\u{F705}"
    public static let f3 = "\u{F706}"
    public static let f4 = "\u{F707}"
    public static let f5 = "\u{F708}"
    public static let f6 = "\u{F709}"
    public static let f7 = "\u{F70A}"
    public static let f8 = "\u{F70B}"
    public static let f9 = "\u{F70C}"
    public static let f10 = "\u{F70D}"
    public static let f11 = "\u{F70E}"
    public static let f12 = "\u{F70F}"

    public static let functionKeys: Set<String> = [
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    ]

    public static func isFunctionKey(_ key: String) -> Bool {
        functionKeys.contains(key)
    }
}

/// Ready-made shortcut layouts.
public enum ShortcutPreset: String, CaseIterable, Codable, Sendable {
    case standard
    case classicCommander

    public var title: String {
        switch self {
        case .standard: return "OpenLift Default"
        case .classicCommander: return "Classic Commander"
        }
    }

    public var detail: String {
        switch self {
        case .standard:
            return "Command-key shortcuts that OpenLift ships with."
        case .classicCommander:
            return "Classic two-pane function keys: F3 view, F5 copy, F6 move, "
                + "F7 new folder, F8 delete, F2 refresh."
        }
    }
}

/// Commands whose shortcuts can be customized.
public enum ShortcutCommand: String, CaseIterable, Codable, Sendable {
    case newFolder
    case rename
    case duplicate
    case moveToTrash
    case quickLook
    case getInfo
    case findInFolder
    case advancedSearch
    case refresh
    case toggleHidden
    case copyToOtherPane
    case moveToOtherPane
    case activity
    case singlePane
    case swapPanes

    public var title: String {
        switch self {
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case .duplicate: return "Duplicate"
        case .moveToTrash: return "Move to Trash"
        case .quickLook: return "Quick Look"
        case .getInfo: return "Get Info"
        case .findInFolder: return "Find in Folder"
        case .advancedSearch: return "Advanced Search"
        case .refresh: return "Refresh"
        case .toggleHidden: return "Show Hidden Files"
        case .copyToOtherPane: return "Copy to Other Pane"
        case .moveToOtherPane: return "Move to Other Pane"
        case .activity: return "Activity"
        case .singlePane: return "Single Pane"
        case .swapPanes: return "Swap Panes"
        }
    }

    public var defaultShortcut: KeyboardShortcut? {
        switch self {
        case .newFolder:
            return KeyboardShortcut(key: "n", modifiers: [.command, .shift])
        case .rename:
            return KeyboardShortcut(key: "\r", modifiers: [])
        case .duplicate:
            return KeyboardShortcut(key: "d", modifiers: [.command])
        case .moveToTrash:
            return KeyboardShortcut(key: "\u{8}", modifiers: [.command])
        case .quickLook:
            return KeyboardShortcut(key: "y", modifiers: [.command])
        case .getInfo:
            return KeyboardShortcut(key: "i", modifiers: [.command])
        case .findInFolder:
            return KeyboardShortcut(key: "f", modifiers: [.command])
        case .advancedSearch:
            return KeyboardShortcut(key: "f", modifiers: [.command, .shift])
        case .refresh:
            return KeyboardShortcut(key: "r", modifiers: [.command])
        case .toggleHidden:
            return KeyboardShortcut(key: ".", modifiers: [.command, .shift])
        case .copyToOtherPane:
            return KeyboardShortcut(key: "c", modifiers: [.command, .control])
        case .moveToOtherPane:
            return KeyboardShortcut(key: "m", modifiers: [.command, .control])
        case .activity:
            return KeyboardShortcut(key: "a", modifiers: [.command, .option])
        case .singlePane:
            return KeyboardShortcut(key: "\\", modifiers: [.command])
        case .swapPanes:
            return KeyboardShortcut(key: "s", modifiers: [.command, .shift])
        }
    }

    /// The shortcut this command gets in a preset.
    public func shortcut(in preset: ShortcutPreset) -> KeyboardShortcut? {
        switch preset {
        case .standard:
            return defaultShortcut
        case .classicCommander:
            return classicCommanderShortcut
        }
    }

    /// Function-key layout modelled on classic two-pane commanders.
    private var classicCommanderShortcut: KeyboardShortcut? {
        switch self {
        case .newFolder:
            return KeyboardShortcut(key: ShortcutKey.f7, modifiers: [])
        case .rename:
            return KeyboardShortcut(key: ShortcutKey.f6, modifiers: [.shift])
        case .duplicate:
            return KeyboardShortcut(key: ShortcutKey.f5, modifiers: [.shift])
        case .moveToTrash:
            return KeyboardShortcut(key: ShortcutKey.f8, modifiers: [])
        case .quickLook:
            return KeyboardShortcut(key: ShortcutKey.f3, modifiers: [])
        case .getInfo:
            return KeyboardShortcut(key: "\r", modifiers: [.option])
        case .findInFolder:
            return KeyboardShortcut(key: "f", modifiers: [.control])
        case .advancedSearch:
            return KeyboardShortcut(key: ShortcutKey.f7, modifiers: [.option])
        case .refresh:
            return KeyboardShortcut(key: ShortcutKey.f2, modifiers: [])
        case .toggleHidden:
            return KeyboardShortcut(key: "h", modifiers: [.control])
        case .copyToOtherPane:
            return KeyboardShortcut(key: ShortcutKey.f5, modifiers: [])
        case .moveToOtherPane:
            return KeyboardShortcut(key: ShortcutKey.f6, modifiers: [])
        case .activity:
            return KeyboardShortcut(key: ShortcutKey.f12, modifiers: [])
        case .singlePane:
            return KeyboardShortcut(key: ShortcutKey.f11, modifiers: [])
        case .swapPanes:
            return KeyboardShortcut(key: "u", modifiers: [.control])
        }
    }
}

/// Stores user overrides for menu shortcuts in `UserDefaults`.
///
/// A missing entry means “use the default”; an entry with a `nil` key means the
/// user cleared the shortcut, so no default comes back.
public final class ShortcutStore: @unchecked Sendable {
    private struct Stored: Codable {
        var key: String?
        var modifiers: ShortcutModifiers
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let queue = DispatchQueue(label: "dev.openlift.shortcuts")

    public init(defaults: UserDefaults = .standard, storageKey: String = "OpenLift.shortcuts") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Currently selected base layout.
    public var preset: ShortcutPreset {
        queue.sync { loadPreset() }
    }

    /// Switches layout and drops per-command overrides, so the result is a
    /// complete, predictable preset.
    public func setPreset(_ preset: ShortcutPreset) {
        queue.sync {
            defaults.set(preset.rawValue, forKey: presetKey)
            defaults.removeObject(forKey: storageKey)
        }
    }

    /// The effective shortcut, or `nil` when the command has none.
    public func shortcut(for command: ShortcutCommand) -> KeyboardShortcut? {
        queue.sync {
            if let stored = loadMap()[command.rawValue] {
                guard let key = stored.key else { return nil }
                return KeyboardShortcut(key: key, modifiers: stored.modifiers)
            }
            return command.shortcut(in: loadPreset())
        }
    }

    public func isCustomized(_ command: ShortcutCommand) -> Bool {
        queue.sync { loadMap()[command.rawValue] != nil }
    }

    /// Overrides a command; pass `nil` to remove its shortcut.
    public func set(_ shortcut: KeyboardShortcut?, for command: ShortcutCommand) {
        queue.sync {
            var map = loadMap()
            map[command.rawValue] = Stored(key: shortcut?.key, modifiers: shortcut?.modifiers ?? [])
            save(map)
        }
    }

    public func reset(_ command: ShortcutCommand) {
        queue.sync {
            var map = loadMap()
            map.removeValue(forKey: command.rawValue)
            save(map)
        }
    }

    /// Restore the selected preset's values, keeping the preset choice.
    public func resetAll() {
        queue.sync {
            defaults.removeObject(forKey: storageKey)
        }
    }

    /// Another command that would receive the same user-visible shortcut.
    public func conflictingCommand(
        for shortcut: KeyboardShortcut,
        excluding command: ShortcutCommand
    ) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { other in
            other != command && self.shortcut(for: other) == shortcut
        }
    }

    private var presetKey: String {
        storageKey + ".preset"
    }

    private func loadPreset() -> ShortcutPreset {
        guard let raw = defaults.string(forKey: presetKey),
              let preset = ShortcutPreset(rawValue: raw) else {
            return .standard
        }
        return preset
    }

    private func loadMap() -> [String: Stored] {
        guard let data = defaults.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: Stored].self, from: data) else {
            return [:]
        }
        return map
    }

    private func save(_ map: [String: Stored]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

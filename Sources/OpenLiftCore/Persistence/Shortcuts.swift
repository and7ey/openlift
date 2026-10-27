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

    /// The effective shortcut, or `nil` when the command has none.
    public func shortcut(for command: ShortcutCommand) -> KeyboardShortcut? {
        queue.sync {
            if let stored = loadMap()[command.rawValue] {
                guard let key = stored.key else { return nil }
                return KeyboardShortcut(key: key, modifiers: stored.modifiers)
            }
            return command.defaultShortcut
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

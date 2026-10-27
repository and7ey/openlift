import AppKit
import OpenLiftCore

/// Formats and captures menu shortcuts.
@MainActor
enum ShortcutFormatting {
    static func displayString(for shortcut: KeyboardShortcut?) -> String {
        guard let shortcut else { return "—" }
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + keyName(shortcut.key)
    }

    private static func keyName(_ key: String) -> String {
        switch key {
        case "\r": return "↩"
        case "\u{8}": return "⌫"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{1b}": return "⎋"
        default: return key.uppercased()
        }
    }

    /// ANSI key equivalents for the physical keys we accept. Storing these
    /// keeps shortcuts independent of the active input source.
    private static let ansiKeys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`"
    ]

    /// Converts a key event into a menu shortcut, or `nil` for a modifier-only
    /// or unsupported key.
    static func shortcut(from event: NSEvent) -> KeyboardShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        let key: String
        switch event.keyCode {
        case 36, 76: key = "\r"
        case 48: key = "\t"
        case 49: key = " "
        case 51: key = "\u{8}"
        case 53: return nil
        default:
            // Use the physical ANSI key rather than the current layout's
            // character, so a shortcut recorded on a Russian layout still
            // matches the same key when the layout switches.
            if let canonical = ansiKeys[event.keyCode] {
                key = canonical
            } else if let characters = event.charactersIgnoringModifiers?.lowercased(),
                      characters.count == 1 {
                key = characters
            } else {
                return nil
            }
        }

        // Bare letters would swallow typing everywhere; Return and Delete are
        // useful without modifiers, as in the default Rename shortcut.
        if modifiers.isEmpty, key != "\r", key != "\u{8}" {
            return nil
        }
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }
}

extension ShortcutModifiers {
    public init(flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }

    public var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// A tiny first-responder view used inside the shortcut sheet.
private final class ShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "Press a key combination")
    private(set) var captured: KeyboardShortcut?
    var onCapture: ((KeyboardShortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    /// Called from the modal alert's local key monitor.
    func handle(_ event: NSEvent) {
        guard let shortcut = ShortcutFormatting.shortcut(from: event) else {
            NSSound.beep()
            return
        }
        captured = shortcut
        label.stringValue = ShortcutFormatting.displayString(for: shortcut)
        label.textColor = .labelColor
        onCapture?(shortcut)
    }
}

/// Lists customizable commands and edits their shortcuts.
@MainActor
public final class ShortcutsWindowController: NSWindowController {
    public var onChange: (() -> Void)?
    /// Returns other commands/menu items already using this shortcut.
    public var conflictTitles: ((KeyboardShortcut, ShortcutCommand) -> [String])?

    private let store: ShortcutStore
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let commands = ShortcutCommand.allCases

    public init(store: ShortcutStore = ShortcutStore()) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        TestWindowPlacement.place(window)
        super.init(window: window)
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func present() {
        tableView.reloadData()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.target = self
        tableView.doubleAction = #selector(changeShortcut(_:))

        let commandColumn = NSTableColumn(identifier: .init("Command"))
        commandColumn.title = "Command"
        commandColumn.width = 300
        tableView.addTableColumn(commandColumn)

        let shortcutColumn = NSTableColumn(identifier: .init("Shortcut"))
        shortcutColumn.title = "Shortcut"
        shortcutColumn.width = 160
        tableView.addTableColumn(shortcutColumn)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeShortcut(_:)))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeShortcut(_:)))
        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        for button in [changeButton, removeButton, restoreButton] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        let hint = NSTextField(labelWithString: "Double-click a command to record a new shortcut.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(hint)
        content.addSubview(changeButton)
        content.addSubview(removeButton)
        content.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: changeButton.centerYAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            changeButton.leadingAnchor.constraint(greaterThanOrEqualTo: hint.trailingAnchor, constant: 8),
            changeButton.centerYAnchor.constraint(equalTo: hint.centerYAnchor),

            removeButton.leadingAnchor.constraint(equalTo: changeButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: changeButton.centerYAnchor),

            restoreButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            restoreButton.centerYAnchor.constraint(equalTo: changeButton.centerYAnchor)
        ])
    }

    // MARK: - Editing

    @objc private func changeShortcut(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < commands.count else { return }
        let command = commands[row]

        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 280, height: 46))
        let alert = NSAlert()
        alert.messageText = "Shortcut for “\(command.title)”"
        alert.informativeText = "Press the key combination you want to use."
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        recorder.onCapture = { _ in
            alert.buttons[0].isEnabled = true
        }
        alert.window.initialFirstResponder = recorder

        // Accessory views do not reliably become first responder inside an
        // NSAlert modal loop, so capture keys before they reach the alert.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { return event } // Escape cancels the alert
            recorder.handle(event)
            return nil
        }
        let response = alert.runModal()
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        switch response {
        case .alertFirstButtonReturn:
            guard let shortcut = recorder.captured else { return }
            let conflicts = conflictTitles?(shortcut, command) ?? []
            if !conflicts.isEmpty {
                let warning = NSAlert()
                warning.messageText = "That shortcut is already in use"
                warning.informativeText = conflicts.joined(separator: "\n")
                warning.addButton(withTitle: "OK")
                warning.runModal()
                return
            }
            store.set(shortcut, for: command)
        case .alertSecondButtonReturn:
            store.set(nil, for: command)
        default:
            return
        }
        tableView.reloadData()
        onChange?()
    }

    @objc private func removeShortcut(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < commands.count else { return }
        store.set(nil, for: commands[row])
        tableView.reloadData()
        onChange?()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        store.resetAll()
        tableView.reloadData()
        onChange?()
    }
}

// MARK: - Table

extension ShortcutsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < commands.count else { return nil }
        let command = commands[row]
        let isShortcut = tableColumn?.identifier.rawValue == "Shortcut"
        let field = NSTextField(labelWithString: isShortcut
            ? ShortcutFormatting.displayString(for: store.shortcut(for: command))
            : command.title)
        field.font = isShortcut
            ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = isShortcut && store.shortcut(for: command) == nil
            ? .tertiaryLabelColor
            : .labelColor
        return field
    }
}

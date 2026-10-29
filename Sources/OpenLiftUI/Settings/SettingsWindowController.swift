import AppKit
import OpenLiftCore
import UniformTypeIdentifiers

/// App settings: view preferences for open folders, history size and About.
///
/// One window is reused; values are pushed in from the active pane each time it
/// opens, and every change is reported back through a closure so the window
/// controller can apply it to all panes in one place.
@MainActor
public final class SettingsWindowController: NSWindowController {
    public var onShowHiddenChanged: ((Bool) -> Void)?
    public var onFoldersFirstChanged: ((Bool) -> Void)?
    public var onLimitsChanged: ((Int) -> Void)?
    public var onResetFolderViews: (() -> Void)?
    public var onEditShortcuts: (() -> Void)?
    public var onThemeChanged: ((Theme) -> Void)?

    private let showHiddenButton = NSButton(
        checkboxWithTitle: "Show hidden files in all open folders",
        target: nil,
        action: nil
    )
    private let foldersFirstButton = NSButton(
        checkboxWithTitle: "Sort folders before files in all open folders",
        target: nil,
        action: nil
    )
    private let themePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editorLabel = NSTextField(labelWithString: "")
    private let chooseEditorButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let resetEditorButton = NSButton(title: "Use TextEdit", target: nil, action: nil)
    private let limitLabel = NSTextField(labelWithString: "50")
    private let limitStepper = NSStepper()
    private let versionLabel = NSTextField(labelWithString: "")

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 545),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        TestWindowPlacement.place(window)

        super.init(window: window)
        configureContent()
        updateEditorLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func present(
        showHidden: Bool,
        foldersFirst: Bool,
        limit: Int,
        version: String,
        theme: Theme = .system
    ) {
        if let index = themePopUp.itemArray.firstIndex(where: { $0.representedObject as? String == theme.id }) {
            themePopUp.selectItem(at: index)
        }
        updateEditorLabel()
        showHiddenButton.state = showHidden ? .on : .off
        foldersFirstButton.state = foldersFirst ? .on : .off
        limitStepper.integerValue = limit
        limitLabel.stringValue = "\(limit)"
        versionLabel.stringValue = "OpenLift \(version)"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        showHiddenButton.target = self
        showHiddenButton.action = #selector(showHiddenChanged(_:))
        foldersFirstButton.target = self
        foldersFirstButton.action = #selector(foldersFirstChanged(_:))

        let shortcutsButton = NSButton(
            title: "Keyboard Shortcuts…",
            target: self,
            action: #selector(editShortcuts(_:))
        )
        shortcutsButton.bezelStyle = .inline
        shortcutsButton.controlSize = .small

        let resetButton = NSButton(
            title: "Reset All Folder Views…",
            target: self,
            action: #selector(resetFolderViews(_:))
        )
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small

        // Appearance
        themePopUp.removeAllItems()
        for theme in Theme.builtIn {
            themePopUp.addItem(withTitle: theme.name)
            themePopUp.lastItem?.representedObject = theme.id
        }
        themePopUp.target = self
        themePopUp.action = #selector(themeChanged(_:))
        themePopUp.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let themeRow = NSStackView(views: [
            NSTextField(labelWithString: "Theme:"),
            themePopUp
        ])
        themeRow.orientation = .horizontal
        themeRow.spacing = 8

        let appearanceHeader = header("Appearance")
        let appearanceStack = NSStackView(views: [
            themeRow,
            secondaryLabel(
                "Themes set the file list background, alternating rows and selection " +
                "color; System follows the macOS light or dark appearance."
            )
        ])
        appearanceStack.orientation = .vertical
        appearanceStack.alignment = .leading
        appearanceStack.spacing = 8

        editorLabel.lineBreakMode = .byTruncatingMiddle
        editorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        chooseEditorButton.target = self
        chooseEditorButton.action = #selector(chooseEditor(_:))
        chooseEditorButton.bezelStyle = .inline
        chooseEditorButton.controlSize = .small
        resetEditorButton.target = self
        resetEditorButton.action = #selector(resetEditor(_:))
        resetEditorButton.bezelStyle = .inline
        resetEditorButton.controlSize = .small

        let editorRow = NSStackView(views: [
            NSTextField(labelWithString: "Edit files with:"),
            editorLabel,
            chooseEditorButton,
            resetEditorButton
        ])
        editorRow.orientation = .horizontal
        editorRow.spacing = 8

        let generalHeader = header("General")
        let generalStack = NSStackView(views: [
            editorRow,
            showHiddenButton,
            foldersFirstButton,
            shortcutsButton,
            resetButton
        ])
        generalStack.orientation = .vertical
        generalStack.alignment = .leading
        generalStack.spacing = 8

        // Activity
        let activityHeader = header("Activity")
        limitStepper.minValue = 10
        limitStepper.maxValue = 500
        limitStepper.increment = 10
        limitStepper.target = self
        limitStepper.action = #selector(limitChanged(_:))
        limitLabel.alignment = .right
        limitLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        limitLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let limitRow = NSStackView(views: [
            NSTextField(labelWithString: "Remember recent operations:"),
            limitLabel,
            limitStepper
        ])
        limitRow.orientation = .horizontal
        limitRow.spacing = 8

        let clearButton = NSButton(
            title: "Clear Activity Log",
            target: self,
            action: #selector(clearActivity(_:))
        )
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small

        let activityStack = NSStackView(views: [limitRow, clearButton])
        activityStack.orientation = .vertical
        activityStack.alignment = .leading
        activityStack.spacing = 8

        // About
        let aboutHeader = header("About")
        versionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let license = secondaryLabel(
            "An independent open-source file manager, MIT licensed. " +
            "Built from scratch in Swift and AppKit."
        )

        let root = NSStackView(views: [
            appearanceHeader,
            appearanceStack,
            separator(),
            generalHeader,
            generalStack,
            separator(),
            activityHeader,
            activityStack,
            separator(),
            aboutHeader,
            versionLabel,
            license
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            license.widthAnchor.constraint(equalToConstant: 470)
        ])
    }

    private func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return label
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return box
    }

    // MARK: - Actions

    @objc private func chooseEditor(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Use Editor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        EditorStore.shared.setApplicationPath(url.path)
        updateEditorLabel()
    }

    @objc private func resetEditor(_ sender: Any?) {
        EditorStore.shared.resetToDefault()
        updateEditorLabel()
    }

    private func updateEditorLabel() {
        editorLabel.stringValue = EditorStore.shared.displayName
        editorLabel.toolTip = EditorStore.shared.resolvedApplicationPath
        resetEditorButton.isEnabled = EditorStore.shared.isCustomized
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let theme = Theme.theme(withID: id) else { return }
        onThemeChanged?(theme)
    }

    @objc private func showHiddenChanged(_ sender: NSButton) {
        onShowHiddenChanged?(sender.state == .on)
    }

    @objc private func foldersFirstChanged(_ sender: NSButton) {
        onFoldersFirstChanged?(sender.state == .on)
    }

    @objc private func limitChanged(_ sender: NSStepper) {
        limitLabel.stringValue = "\(sender.integerValue)"
        onLimitsChanged?(sender.integerValue)
    }

    @objc private func clearActivity(_ sender: Any?) {
        ActivityLog.shared.clear()
    }

    @objc private func editShortcuts(_ sender: Any?) {
        onEditShortcuts?()
    }

    @objc private func resetFolderViews(_ sender: Any?) {
        onResetFolderViews?()
    }
}

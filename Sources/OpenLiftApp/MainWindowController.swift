import AppKit
import OpenLiftCore
import OpenLiftUI

/// Owns the browser window: sidebar, two tabbed panes, toolbar and command routing.
///
/// Mirrors a classic dual-pane manager's window controller: one hub validates
/// and executes commands from the menu, toolbar and keyboard.
@MainActor
public final class MainWindowController: NSWindowController {
    private let sidebarViewController: SidebarViewController
    private let leftTabs: BrowserTabsViewController
    private let rightTabs: BrowserTabsViewController
    private let rootSplit: NSSplitViewController
    private let panesSplit: NSSplitViewController
    private let stateStore: WindowStateStore
    private let viewSettingsStore: ViewSettingsStore
    private let history = OperationHistory()
    private var activityWindowController: ActivityWindowController?
    private var infoWindowController: InfoWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var shortcutsWindowController: ShortcutsWindowController?
    private var searchWindowController: AdvancedSearchWindowController?
    private var remoteConnectionController: RemoteConnectionWindowController?
    private var folderCompareController: FolderCompareWindowController?
    private let bookmarkStore = RemoteBookmarkStore()
    private let themeStore = ThemeStore.shared
    private var currentTheme = Theme.system
    private let shortcuts = ShortcutStore()

    private var isSinglePane = false
    private var activePaneIndex = 0
    /// Swallows Tab so focus cycles between the two file panes only.
    nonisolated(unsafe) private var tabKeyMonitor: Any?

    private var activeTabs: BrowserTabsViewController {
        activePaneIndex == 0 ? leftTabs : rightTabs
    }

    private var otherTabs: BrowserTabsViewController {
        activePaneIndex == 0 ? rightTabs : leftTabs
    }

    private var activePane: BrowserPaneViewController { activeTabs.activePane }
    private var otherPane: BrowserPaneViewController { otherTabs.activePane }
    private var allPanes: [BrowserPaneViewController] { leftTabs.panes + rightTabs.panes }

    public init(stateStore: WindowStateStore = WindowStateStore()) {
        self.stateStore = stateStore
        let settingsStore = ViewSettingsStore()
        viewSettingsStore = settingsStore

        let provider = LocalFileProvider()
        let state = stateStore.load()

        sidebarViewController = SidebarViewController()
        leftTabs = BrowserTabsViewController(
            provider: provider,
            settingsStore: settingsStore,
            initialTabs: state.leftTabs ?? [state.left],
            activeTab: state.leftActiveTab ?? 0
        )
        rightTabs = BrowserTabsViewController(
            provider: provider,
            settingsStore: settingsStore,
            initialTabs: state.rightTabs ?? [state.right],
            activeTab: state.rightActiveTab ?? 0
        )

        panesSplit = NSSplitViewController()
        rootSplit = NSSplitViewController()

        let window = NSWindow(
            contentRect: state.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenLift"
        window.minSize = NSSize(width: 720, height: 420)
        window.tabbingMode = .disallowed

        super.init(window: window)
        TestWindowPlacement.placeMainWindow(window)

        configureSplitView(state: state)
        configurePanes()
        configureSidebar()
        configureToolbar()
        observeModels()
        installTabKeyMonitor()
        applyTheme(themeStore.current, persist: false)
        updateWindowTitle()
        TestWindowPlacement.placeMainWindow(window)

        if state.singlePane {
            isSinglePane = true
            panesSplit.splitViewItems.last?.isCollapsed = true
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let total = self.panesSplit.splitView.bounds.width
            if total > 0, !self.isSinglePane {
                self.panesSplit.splitView.setPosition(total * state.splitRatio, ofDividerAt: 0)
            }
            if state.sidebarWidth > 0 {
                let width = min(max(state.sidebarWidth, 160), 340)
                self.rootSplit.splitView.setPosition(width, ofDividerAt: 0)
            }
            self.activatePane(self.activePaneIndex)
            let tabs = self.activePaneIndex == 0 ? self.leftTabs : self.rightTabs
            tabs.activePane.activate()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func configureSplitView(state: WindowState) {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .init(260)

        let panesItem = NSSplitViewItem(viewController: panesSplit)
        panesItem.minimumThickness = 320
        panesItem.holdingPriority = .init(250)

        rootSplit.splitView.isVertical = true
        rootSplit.addSplitViewItem(sidebarItem)
        rootSplit.addSplitViewItem(panesItem)

        let leftItem = NSSplitViewItem(viewController: leftTabs)
        leftItem.minimumThickness = 260
        let rightItem = NSSplitViewItem(viewController: rightTabs)
        rightItem.minimumThickness = 260

        panesSplit.splitView.isVertical = true
        panesSplit.splitView.dividerStyle = .thin
        panesSplit.addSplitViewItem(leftItem)
        panesSplit.addSplitViewItem(rightItem)

        window?.contentViewController = rootSplit
        window?.setFrame(state.frame, display: true)
    }

    private func configurePanes() {
        leftTabs.onActivate = { [weak self] in self?.activatePane(0) }
        rightTabs.onActivate = { [weak self] in self?.activatePane(1) }
        leftTabs.onOperation = { [weak self] record in self?.history.record(record) }
        rightTabs.onOperation = { [weak self] record in self?.history.record(record) }

        history.onChange = { [weak self] in
            guard let self else { return }
            self.leftTabs.panes.forEach { $0.model.reload() }
            self.rightTabs.panes.forEach { $0.model.reload() }
        }
        history.onError = { [weak self] error in
            self?.presentOperationError(error)
        }

        let appSettings = AppSettingsStore.shared
        history.limit = appSettings.settings.undoLimit
        ActivityLog.shared.limit = appSettings.settings.activityLimit
        appSettings.onChange = { [weak self] settings in
            self?.history.limit = settings.undoLimit
            ActivityLog.shared.limit = settings.activityLimit
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenInOtherPane(_:)),
            name: .openLiftOpenInOtherPane,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGetInfo(_:)),
            name: .openLiftGetInfo,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAdvancedSearch(_:)),
            name: .openLiftAdvancedSearch,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenArchive(_:)),
            name: .openLiftOpenArchive,
            object: nil
        )
    }

    private func configureSidebar() {
        sidebarViewController.onSelect = { [weak self] url in
            guard let self else { return }
            if self.activePane.model.isSearchResults || self.activePane.model.isRemote || self.activePane.model.isArchive {
                self.activeTabs.newTab(at: url)
            } else {
                self.activePane.model.navigate(to: url)
            }
        }
    }

    private func configureToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "OpenLiftToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    private func observeModels() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(browserModelDidChange(_:)),
            name: .openLiftBrowserModelDidChange,
            object: nil
        )
    }

    private func activatePane(_ index: Int) {
        activePaneIndex = index
        leftTabs.activePane.isActivePane = index == 0
        rightTabs.activePane.isActivePane = index == 1
        updateWindowTitle()
    }

    deinit {
        if let tabKeyMonitor {
            NSEvent.removeMonitor(tabKeyMonitor)
        }
    }

    // MARK: - Keyboard focus

    /// Tab and Shift-Tab cycle the two panes, never the sidebar, toolbar or
    /// tab bar. Text fields keep working normally because Tab is a focus
    /// command there too: editing ends and the other pane takes focus.
    private func installTabKeyMonitor() {
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated {
                self?.handleTabKey(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    eventWindow: event.window
                ) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleTabKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        eventWindow: NSWindow?
    ) -> Bool {
        // Events posted by the test harness carry no window; treat them as
        // belonging to this window (the app has one main window).
        guard keyCode == 48,
              eventWindow === window || eventWindow == nil,
              let window else { return false }
        // Caps Lock, Fn and stray flags from synthetic events do not matter;
        // only shortcuts with Command, Control or Option keep their meaning.
        let reserved: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifiers.intersection(reserved).isEmpty else { return false }

        if isSinglePane {
            activeTabs.activePane.activate()
            return true
        }

        let responder = window.firstResponder
        let target: Int
        if focusIsInside(leftTabs, responder: responder) {
            target = 1
        } else if focusIsInside(rightTabs, responder: responder) {
            target = 0
        } else {
            // Coming from the sidebar or toolbar: return to the pane that was
            // active rather than guessing a direction.
            target = activePaneIndex
        }

        activatePane(target)
        (target == 0 ? leftTabs : rightTabs).activePane.activate()
        return true
    }

    private func focusIsInside(_ tabs: BrowserTabsViewController, responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        let root = tabs.view
        return view === root || view.isDescendant(of: root)
    }

    // MARK: - Themes

    private func applyTheme(_ theme: Theme, persist: Bool = true) {
        currentTheme = theme
        NSApp.appearance = theme.appearance.nsAppearance
        leftTabs.applyTheme(theme)
        rightTabs.applyTheme(theme)
        if persist {
            themeStore.select(theme)
        }
    }

    @objc func setTheme(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let id = item.representedObject as? String,
              let theme = Theme.theme(withID: id) else { return }
        applyTheme(theme)
    }

    // MARK: - Shortcuts

    /// Selector behind each customizable command.
    private static let shortcutSelectors: [ShortcutCommand: Selector] = [
        .openItem: #selector(openSelection(_:)),
        .goUp: #selector(goUp(_:)),
        .newFolder: #selector(newFolder(_:)),
        .rename: #selector(renameSelection(_:)),
        .duplicate: #selector(duplicateSelection(_:)),
        .moveToTrash: #selector(moveToTrash(_:)),
        .quickLook: #selector(quickLook(_:)),
        .getInfo: #selector(showInfo(_:)),
        .calculateFolderSize: #selector(calculateFolderSizes(_:)),
        .findInFolder: #selector(find(_:)),
        .refresh: #selector(refresh(_:)),
        .toggleHidden: #selector(toggleHiddenFiles(_:)),
        .copyToOtherPane: #selector(copyToOtherPane(_:)),
        .moveToOtherPane: #selector(moveToOtherPane(_:)),
        .activity: #selector(showActivity(_:)),
        .singlePane: #selector(toggleSinglePane(_:)),
        .swapPanes: #selector(swapPanes(_:)),
        .advancedSearch: #selector(showAdvancedSearch(_:))
    ]

    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindowController == nil {
            let controller = ShortcutsWindowController(store: shortcuts)
            controller.onChange = { [weak self] in self?.applyShortcuts() }
            controller.conflictTitles = { [weak self] shortcut, command in
                self?.shortcutConflicts(for: shortcut, excluding: command) ?? []
            }
            shortcutsWindowController = controller
        }
        shortcutsWindowController?.present()
    }

    /// Pushes the stored shortcuts (defaults or overrides) onto the menu items.
    public func applyShortcuts() {
        guard let menu = NSApp.mainMenu else { return }
        applyShortcuts(to: menu)
    }

    private func applyShortcuts(to menu: NSMenu) {
        for item in menu.items {
            if let action = item.action,
               let command = Self.shortcutSelectors.first(where: { $0.value == action })?.key {
                let shortcut = shortcuts.shortcut(for: command)
                item.keyEquivalent = shortcut?.key ?? ""
                item.keyEquivalentModifierMask = shortcut?.modifiers.eventFlags ?? []
            }
            if let submenu = item.submenu {
                applyShortcuts(to: submenu)
            }
        }
    }

    /// Menu items (including non-customizable ones) that already use this
    /// shortcut, so the recorder can refuse duplicates such as ⌘O.
    private func shortcutConflicts(
        for shortcut: KeyboardShortcut,
        excluding command: ShortcutCommand
    ) -> [String] {
        guard let menu = NSApp.mainMenu else { return [] }
        let editedSelector = Self.shortcutSelectors[command]
        var titles: [String] = []

        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if item.action != editedSelector,
                   item.keyEquivalent == shortcut.key,
                   ShortcutModifiers(flags: item.keyEquivalentModifierMask) == shortcut.modifiers {
                    titles.append(item.title)
                }
                if let submenu = item.submenu {
                    visit(submenu)
                }
            }
        }
        visit(menu)
        return titles
    }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            controller.onShowHiddenChanged = { [weak self] value in
                self?.allPanes.forEach { $0.model.settings.showHidden = value }
            }
            controller.onFoldersFirstChanged = { [weak self] value in
                self?.allPanes.forEach { pane in
                    var sort = pane.model.settings.sort
                    sort.foldersFirst = value
                    pane.model.settings.sort = sort
                }
            }
            controller.onLimitsChanged = { value in
                AppSettingsStore.shared.update(
                    AppSettings(undoLimit: value, activityLimit: value)
                )
            }
            controller.onResetFolderViews = { [weak self] in
                self?.confirmResetFolderViews()
            }
            controller.onEditShortcuts = { [weak self] in
                self?.showShortcuts(nil)
            }
            controller.onThemeChanged = { [weak self] theme in
                self?.applyTheme(theme)
            }
            settingsWindowController = controller
        }

        let appSettings = AppSettingsStore.shared.settings
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        settingsWindowController?.present(
            showHidden: activePane.model.settings.showHidden,
            foldersFirst: activePane.model.settings.sort.foldersFirst,
            limit: min(appSettings.undoLimit, appSettings.activityLimit),
            version: version,
            theme: currentTheme
        )
    }

    private func confirmResetFolderViews() {
        let alert = NSAlert()
        alert.messageText = "Reset all folder views?"
        alert.informativeText = "Every folder will forget its sort order, grouping, hidden-file and list/icon setting."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        viewSettingsStore.removeAll()
        allPanes.forEach { $0.model.settings = .default }
    }

    // MARK: - Navigation

    @objc func goToFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Enter a path, for example ~/Pictures or /tmp."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = activePane.model.isSearchResults
            ? NSHomeDirectory()
            : activePane.model.directory.path
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let path = (field.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        if activePane.model.isArchive {
            NSSound.beep()
            return
        }
        if activePane.model.isRemote {
            var components = URLComponents(
                url: activePane.model.directory,
                resolvingAgainstBaseURL: false
            )
            components?.percentEncodedPath = (path.hasPrefix("/") ? path : "/" + path)
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            if let url = components?.url {
                activePane.model.navigate(to: url)
            }
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if activePane.model.isSearchResults {
            activeTabs.newTab(at: url)
        } else {
            activePane.model.navigate(to: url)
        }
    }

    // MARK: - Folder comparison

    @objc func compareFolders(_ sender: Any?) {
        let left = leftTabs.activePane.model.directory
        let right = rightTabs.activePane.model.directory
        guard left.isFileURL, right.isFileURL,
              !leftTabs.activePane.model.isSearchResults,
              !rightTabs.activePane.model.isSearchResults,
              !leftTabs.activePane.model.isRemote,
              !rightTabs.activePane.model.isRemote else {
            NSSound.beep()
            return
        }
        guard left.standardizedFileURL != right.standardizedFileURL else {
            NSSound.beep()
            return
        }
        if folderCompareController == nil {
            let controller = FolderCompareWindowController()
            controller.onReload = { [weak self] in
                guard let self else { return }
                for pane in self.leftTabs.panes + self.rightTabs.panes {
                    pane.model.reload()
                }
            }
            folderCompareController = controller
        }
        folderCompareController?.present(left: left, right: right)
    }

    // MARK: - Archives

    @objc func openArchive(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .archive]
        panel.prompt = "Open Archive"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openArchiveInTab(url)
        }
    }

    @objc private func handleOpenArchive(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        openArchiveInTab(url)
    }

    private func openArchiveInTab(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reader = try ArchiveReader(url: url)
                let entries = try await reader.entries()
                let provider = ArchiveFileProvider(reader: reader, entries: entries)
                self.activeTabs.newArchiveTab(provider: provider, directory: provider.root)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not open archive"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc func extractToOtherPane(_ sender: Any?) {
        guard activePane.model.isArchive,
              !otherPane.model.isRemote,
              !otherPane.model.isArchive else {
            NSSound.beep()
            return
        }
        activePane.extractSelection(to: otherPane.model.directory)
    }

    // MARK: - Git

    @objc func refreshGitStatus(_ sender: Any?) {
        activePane.refreshGitStatus()
    }

    @objc func stageGitSelection(_ sender: Any?) {
        guard let snapshot = activePane.currentGitSnapshot else { NSSound.beep(); return }
        let paths = activePane.repositoryRelativePaths(for: activePane.selectedItems)
        guard !paths.isEmpty else { NSSound.beep(); return }
        let items = activePane.selectedItems
        runGitAction(
            title: items.count == 1 ? "Stage “\(items[0].name)”" : "Stage \(items.count) items",
            detail: snapshot.root.path
        ) {
            try await GitClient.stage(paths, at: snapshot.root)
        }
    }

    @objc func unstageGitSelection(_ sender: Any?) {
        guard let snapshot = activePane.currentGitSnapshot else { NSSound.beep(); return }
        let paths = activePane.repositoryRelativePaths(for: activePane.selectedItems)
        guard !paths.isEmpty else { NSSound.beep(); return }
        let items = activePane.selectedItems
        runGitAction(
            title: items.count == 1 ? "Unstage “\(items[0].name)”" : "Unstage \(items.count) items",
            detail: snapshot.root.path
        ) {
            try await GitClient.unstage(paths, at: snapshot.root)
        }
    }

    @objc func discardGitChanges(_ sender: Any?) {
        guard let snapshot = activePane.currentGitSnapshot else { NSSound.beep(); return }
        let paths = activePane.repositoryRelativePaths(for: activePane.selectedItems)
        guard !paths.isEmpty else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = paths.count == 1
            ? "Discard changes in “\(paths[0])”?"
            : "Discard changes in \(paths.count) items?"
        alert.informativeText = "Tracked files are restored to the last commit and untracked files are deleted. This cannot be undone."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let window else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runGitAction(title: "Discard Changes", detail: snapshot.root.path) {
                try await GitClient.discardChanges(paths, at: snapshot.root)
            }
        }
    }

    @objc func commitGitChanges(_ sender: Any?) {
        guard let snapshot = activePane.currentGitSnapshot, let window else {
            NSSound.beep()
            return
        }
        let staged = snapshot.entries.filter(\.hasStagedChanges).count
        let unstaged = snapshot.entries.count - staged

        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 340, height: 24))
        field.placeholderString = "Commit message"
        let stageAll = NSButton(checkboxWithTitle: "Stage all changes first", target: nil, action: nil)
        stageAll.frame = NSRect(x: 0, y: 0, width: 340, height: 20)
        stageAll.state = staged == 0 ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(stageAll)

        let alert = NSAlert()
        alert.messageText = "Commit to \(snapshot.branch)"
        alert.informativeText = staged == 0
            ? "Nothing is staged. \(unstaged) changed file\(unstaged == 1 ? "" : "s") can be staged for this commit."
            : "\(staged) staged, \(unstaged) not staged."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                NSSound.beep()
                return
            }
            let shouldStageAll = stageAll.state == .on
            self?.runGitAction(title: "Commit", detail: snapshot.root.path, refresh: true) {
                if shouldStageAll {
                    try await GitClient.stageAll(at: snapshot.root)
                }
                try await GitClient.commit(message: message, at: snapshot.root)
            }
        }
    }

    private func runGitAction(
        title: String,
        detail: String,
        refresh: Bool = true,
        work: @escaping () async throws -> Void
    ) {
        Task { [weak self] in
            let id = ActivityLog.shared.begin(title: title, detail: detail)
            do {
                try await work()
                ActivityLog.shared.finish(id, status: .completed)
            } catch {
                ActivityLog.shared.finish(id, status: .failed, message: error.localizedDescription)
                self?.presentGitError(error)
            }
            if refresh {
                self?.activePane.refreshGitStatus()
            }
        }
    }

    private func presentGitError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git command failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Remote

    @objc func connectToServer(_ sender: Any?) {
        presentRemoteConnection(prefill: nil)
    }

    private func presentRemoteConnection(prefill: RemoteConnection?) {
        if remoteConnectionController == nil {
            let controller = RemoteConnectionWindowController()
            controller.onConnect = { [weak self] connection, save in
                guard let self else { return }
                if save {
                    self.bookmarkStore.add(RemoteBookmark(connection: connection))
                }
                let provider = RemoteProviderFactory.make(connection)
                self.activeTabs.newRemoteTab(
                    provider: provider,
                    directory: connection.rootURL
                )
            }
            remoteConnectionController = controller
        }
        remoteConnectionController?.present(on: window, prefill: prefill)
    }

    @objc private func connectBookmark(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let id = UUID(uuidString: raw),
              let bookmark = bookmarkStore.load().first(where: { $0.id == id }) else { return }
        presentRemoteConnection(prefill: bookmark.connection)
    }

    @objc private func forgetBookmarks(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Forget all saved servers?"
        alert.informativeText = "Saved addresses are removed. Passwords were never stored."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bookmarkStore.removeAll()
    }

    @objc func downloadToOtherPane(_ sender: Any?) {
        guard activePane.model.isRemote, !otherPane.model.isRemote else {
            NSSound.beep()
            return
        }
        activePane.downloadSelection(to: otherPane.model.directory)
    }

    @objc func uploadToOtherPane(_ sender: Any?) {
        guard !activePane.model.isRemote, otherPane.model.isRemote else {
            NSSound.beep()
            return
        }
        let sources = activePane.selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        otherPane.uploadSelection(sources)
    }

    // MARK: - Search

    @objc func find(_ sender: Any?) {
        activePane.beginSearch()
    }

    @objc func showAdvancedSearch(_ sender: Any?) {
        guard !activePane.model.isSearchResults, !activePane.model.isRemote else { return }
        presentAdvancedSearch(
            root: activePane.model.directory,
            recursive: true,
            focusContent: false
        )
    }

    @objc private func handleAdvancedSearch(_ notification: Notification) {
        guard let root = notification.userInfo?["root"] as? URL else { return }
        presentAdvancedSearch(
            root: root,
            recursive: notification.userInfo?["recursive"] as? Bool ?? true,
            focusContent: notification.userInfo?["focusContent"] as? Bool ?? false
        )
    }

    // MARK: - Testing hooks

    func testNavigate(to url: URL) {
        activePane.model.navigate(to: url)
    }

    func testSetTheme(_ id: String) {
        guard let theme = Theme.theme(withID: id) else { return }
        applyTheme(theme)
    }

    func testNewTab(at url: URL) {
        activeTabs.newTab(at: url)
    }

    func testOpenAdvancedSearch(root: URL, recursive: Bool, focusContent: Bool) {
        presentAdvancedSearch(root: root, recursive: recursive, focusContent: focusContent)
    }

    func testSelectTab(_ index: Int) {
        activeTabs.selectTab(index)
    }

    func testOpenRemote(_ connection: RemoteConnection) {
        let provider = RemoteProviderFactory.make(connection)
        activeTabs.newRemoteTab(provider: provider, directory: connection.rootURL)
    }

    /// Invokes a whitelisted selector on the active pane or the controller.
    @discardableResult
    func testInvoke(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        if activePane.responds(to: selector) {
            activePane.perform(selector, with: nil)
            return true
        }
        if responds(to: selector) {
            perform(selector, with: nil)
            return true
        }
        return false
    }

    private func presentAdvancedSearch(root: URL, recursive: Bool, focusContent: Bool) {
        guard root.isFileURL else { return }
        if searchWindowController == nil {
            let controller = AdvancedSearchWindowController()
            controller.onShowInTab = { [weak self] items in
                self?.activeTabs.newSearchResultsTab(items: items)
            }
            controller.onOpenFolder = { [weak self] url in
                self?.activeTabs.newTab(at: url)
            }
            searchWindowController = controller
        }
        searchWindowController?.present(
            scope: root,
            recursive: recursive,
            focusContent: focusContent
        )
    }

    // MARK: - Quick Look and info

    @objc func quickLook(_ sender: Any?) {
        activePane.performQuickLook()
    }

    @objc func showInfo(_ sender: Any?) {
        presentInfo(for: activePane.selectedItems.map(\.url))
    }

    @objc func calculateFolderSizes(_ sender: Any?) {
        activePane.calculateFolderSizes()
    }

    @objc private func handleGetInfo(_ notification: Notification) {
        guard let urls = notification.userInfo?["urls"] as? [URL], !urls.isEmpty else { return }
        presentInfo(for: urls)
    }

    private func presentInfo(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        if infoWindowController == nil {
            infoWindowController = InfoWindowController()
        }
        infoWindowController?.showInfo(for: urls)
    }

    // MARK: - Activity

    @objc func showActivity(_ sender: Any?) {
        if activityWindowController == nil {
            activityWindowController = ActivityWindowController()
        }
        activityWindowController?.present()
    }

    // MARK: - Undo

    @objc func undo(_ sender: Any?) {
        history.undo()
    }

    @objc func redo(_ sender: Any?) {
        history.redo()
    }

    private func presentOperationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The operation could not be completed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func updateWindowTitle() {
        if activePane.model.isArchive {
            window?.title = activePane.model.displayName
            window?.subtitle = "Archive"
            return
        }
        if activePane.model.isRemote {
            let provider = activePane.model.fileProvider
            let path = activePane.model.directory.path
            window?.title = path == "/" ? provider.displayName : activePane.model.directory.lastPathComponent
            window?.subtitle = provider.displayName
            return
        }
        if activePane.model.isSearchResults {
            window?.title = "Search Results"
            window?.subtitle = "Recursive search results"
            return
        }
        window?.title = activePane.model.displayName
        window?.subtitle = activePane.model.directory.deletingLastPathComponent().path
    }

    @objc private func browserModelDidChange(_ notification: Notification) {
        guard let model = notification.object as? BrowserModel else { return }
        if model === activePane.model {
            updateWindowTitle()
        }
    }

    @objc private func handleOpenInOtherPane(_ notification: Notification) {
        guard let sender = notification.object as? BrowserPaneViewController,
              let url = notification.userInfo?["url"] as? URL else { return }
        let target = sender === leftTabs.activePane ? rightTabs : leftTabs
        target.activePane.model.navigate(to: url)
        target.activePane.activate()
    }

    // MARK: - State

    public func saveWindowState() {
        guard let window else { return }
        let left = leftTabs.tabStates()
        let right = rightTabs.tabStates()

        let state = WindowState(
            frame: window.frame,
            sidebarWidth: sidebarWidth(),
            splitRatio: splitRatio(),
            singlePane: isSinglePane,
            horizontalPanes: false,
            left: left.first ?? PaneState(path: NSHomeDirectory()),
            right: right.first ?? PaneState(path: NSHomeDirectory()),
            activePane: activePaneIndex,
            leftTabs: left,
            rightTabs: right,
            leftActiveTab: leftTabs.activeIndex,
            rightActiveTab: rightTabs.activeIndex
        )
        stateStore.save(state)
    }

    private func splitRatio() -> Double {
        let left = leftTabs.view.frame.width
        let right = rightTabs.view.frame.width
        let total = left + right
        guard total > 0 else { return 0.5 }
        return Double(left / total)
    }

    private func sidebarWidth() -> Double {
        Double(sidebarViewController.view.frame.width)
    }

    // MARK: - Commands

    @objc public func goBack(_ sender: Any?) {
        guard !activePane.model.isSearchResults else { return }
        activePane.model.goBack()
    }

    @objc public func goForward(_ sender: Any?) {
        guard !activePane.model.isSearchResults else { return }
        activePane.model.goForward()
    }

    @objc public func goUp(_ sender: Any?) {
        guard !activePane.model.isSearchResults else { return }
        activePane.model.goUp()
    }

    @objc public func goHome(_ sender: Any?) {
        guard !activePane.model.isSearchResults else { return }
        if activePane.model.isArchive {
            NSSound.beep()
            return
        }
        if activePane.model.isRemote {
            var components = URLComponents(
                url: activePane.model.directory,
                resolvingAgainstBaseURL: false
            )
            components?.percentEncodedPath = "/"
            if let url = components?.url {
                activePane.model.navigate(to: url)
            }
            return
        }
        if activePane.model.isArchive,
           let provider = activePane.model.fileProvider as? ArchiveFileProvider {
            activePane.model.navigate(to: provider.root)
            return
        }
        activePane.model.navigate(to: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }
    @objc public func refresh(_ sender: Any?) { activePane.model.reload() }
    @objc public func openSelection(_ sender: Any?) { activePane.openSelection() }

    @objc public func compressSelection(_ sender: Any?) { activePane.compressSelection() }

    @objc public func batchRenameSelection(_ sender: Any?) { activePane.performBatchRename() }

    @objc public func toggleHiddenFiles(_ sender: Any?) {
        activePane.model.settings.showHidden.toggle()
    }

    @objc public func toggleSinglePane(_ sender: Any?) {
        isSinglePane.toggle()
        panesSplit.splitViewItems.last?.isCollapsed = isSinglePane
    }

    @objc public func swapPanes(_ sender: Any?) {
        let leftURL = leftTabs.activePane.model.directory
        let rightURL = rightTabs.activePane.model.directory
        leftTabs.activePane.model.navigate(to: rightURL)
        rightTabs.activePane.model.navigate(to: leftURL)
    }

    @objc public func toggleSidebar(_ sender: Any?) {
        rootSplit.splitViewItems.first?.isCollapsed.toggle()
    }

    @objc public func newFolder(_ sender: Any?) {
        activePane.performNewFolder()
    }

    @objc public func renameSelection(_ sender: Any?) {
        activePane.performRename()
    }

    @objc public func duplicateSelection(_ sender: Any?) {
        activePane.performDuplicate()
    }

    @objc public func moveToTrash(_ sender: Any?) {
        activePane.performMoveToTrash()
    }

    @objc public func copyToOtherPane(_ sender: Any?) {
        activePane.transferSelection(to: otherPane.model.directory, kind: .copy)
    }

    @objc public func moveToOtherPane(_ sender: Any?) {
        activePane.transferSelection(to: otherPane.model.directory, kind: .move)
    }

    // MARK: - Clipboard

    @objc public func cut(_ sender: Any?) {
        activePane.cut(sender)
    }

    @objc public func copy(_ sender: Any?) {
        activePane.copy(sender)
    }

    @objc public func paste(_ sender: Any?) {
        activePane.paste(sender)
    }

    @objc public func revealInFinder(_ sender: Any?) {
        activePane.performRevealInFinder()
    }

    @objc public func openInTerminal(_ sender: Any?) {
        activePane.performOpenInTerminal()
    }

    @objc public func setViewMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let mode = ViewSettings.Mode(rawValue: raw) else { return }
        activePane.model.settings.mode = mode
    }

    @objc public func sortBy(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let key = SortKey(rawValue: raw) else { return }
        activePane.model.applySort(key, ascending: true)
    }

    @objc public func groupBy(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let key = GroupKey(rawValue: raw) else { return }
        activePane.model.settings.group = key
    }

    // MARK: - Tabs

    @objc public func newTab(_ sender: Any?) {
        activeTabs.newTab()
    }

    @objc public func closeTab(_ sender: Any?) {
        if activeTabs.panes.count > 1 {
            activeTabs.closeActiveTab()
        } else {
            window?.performClose(sender)
        }
    }

    @objc public func showNextTab(_ sender: Any?) {
        activeTabs.selectNextTab()
    }

    @objc public func showPreviousTab(_ sender: Any?) {
        activeTabs.selectPreviousTab()
    }

    @objc public func showActivities(_ sender: Any?) {
        // M2: activity window.
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation {
    /// True while a field editor has focus. Menu key equivalents are disabled
    /// then, so plain Return/Backspace reach the text field instead of opening
    /// a folder or navigating up.
    private var isEditingText: Bool {
        window?.firstResponder is NSTextView
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSelection(_:)):
            return !isEditingText && !activePane.selectedItems.isEmpty
        case #selector(goUp(_:)):
            return !isEditingText && !activePane.model.isSearchResults && activePane.model.canGoUp
        case #selector(undo(_:)):
            menuItem.title = history.undoTitle
            return history.canUndo
        case #selector(redo(_:)):
            menuItem.title = history.redoTitle
            return history.canRedo
        case #selector(cut(_:)), #selector(copy(_:)):
            return !activePane.model.isRemote
                && !activePane.model.isArchive
                && !activePane.selectedItems.isEmpty
        case #selector(paste(_:)):
            return !activePane.model.isSearchResults
                && !activePane.model.isRemote
                && !activePane.model.isArchive
                && !FileClipboard.shared.urls.isEmpty
        case #selector(newFolder(_:)):
            return !activePane.model.isSearchResults && !activePane.model.isArchive
        case #selector(renameSelection(_:)), #selector(moveToTrash(_:)):
            return !activePane.model.isArchive && !activePane.selectedItems.isEmpty
        case #selector(calculateFolderSizes(_:)):
            return !activePane.model.isRemote
                && !activePane.model.isArchive
                && !activePane.model.isSearchResults
                && (activePane.selectedItems.contains(where: \.isDirectory)
                    || activePane.model.displayItems.contains(where: \.isDirectory))
        case #selector(showAdvancedSearch(_:)):
            return !activePane.model.isRemote
                && !activePane.model.isArchive
                && !activePane.model.isSearchResults
        case #selector(batchRenameSelection(_:)), #selector(compressSelection(_:)),
             #selector(duplicateSelection(_:)):
            return !activePane.model.isRemote
                && !activePane.model.isArchive
                && !activePane.selectedItems.isEmpty
        case #selector(downloadToOtherPane(_:)):
            return activePane.model.isRemote
                && !otherPane.model.isRemote
                && !activePane.selectedItems.isEmpty
        case #selector(compareFolders(_:)):
            return !activePane.model.isRemote
                && !otherPane.model.isRemote
                && !activePane.model.isArchive
                && !otherPane.model.isArchive
                && !activePane.model.isSearchResults
                && !otherPane.model.isSearchResults
        case #selector(extractToOtherPane(_:)):
            return activePane.model.isArchive
                && !otherPane.model.isRemote
                && !otherPane.model.isArchive
                && !otherPane.model.isSearchResults
                && !activePane.selectedItems.isEmpty
        case #selector(stageGitSelection(_:)),
             #selector(unstageGitSelection(_:)),
             #selector(discardGitChanges(_:)):
            return activePane.currentGitSnapshot != nil
                && !activePane.repositoryRelativePaths(for: activePane.selectedItems).isEmpty
        case #selector(commitGitChanges(_:)):
            return activePane.currentGitSnapshot != nil
        case #selector(setTheme(_:)):
            if let id = menuItem.representedObject as? String {
                menuItem.state = currentTheme.id == id ? .on : .off
            }
            return true
        case #selector(refreshGitStatus(_:)):
            return activePane.model.directory.isFileURL
                && !activePane.model.isRemote
                && !activePane.model.isArchive
                && !activePane.model.isSearchResults
        case #selector(uploadToOtherPane(_:)):
            return !activePane.model.isRemote
                && otherPane.model.isRemote
                && !activePane.selectedItems.isEmpty
        case #selector(goBack(_:)):
            return !activePane.model.isSearchResults && activePane.model.canGoBack
        case #selector(goForward(_:)):
            return !activePane.model.isSearchResults && activePane.model.canGoForward
        case #selector(goUp(_:)), #selector(goHome(_:)):
            return !activePane.model.isSearchResults
        case #selector(quickLook(_:)), #selector(showInfo(_:)):
            return !activePane.selectedItems.isEmpty
        default:
            return true
        }
    }
}

// MARK: - Toolbar

extension MainWindowController: NSToolbarDelegate {
    private static let identifiers: [NSToolbarItem.Identifier] = [
        .init("back"), .init("forward"), .init("up"), .flexibleSpace,
        .init("newFolder"), .init("trash"), .init("hidden")
    ]

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.identifiers
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == .flexibleSpace || identifier == .space {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "back":
            item.label = "Back"
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
            item.action = #selector(goBack(_:))
        case "forward":
            item.label = "Forward"
            item.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")
            item.action = #selector(goForward(_:))
        case "up":
            item.label = "Enclosing Folder"
            item.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Enclosing Folder")
            item.action = #selector(goUp(_:))
        case "newFolder":
            item.label = "New Folder"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")
            item.action = #selector(newFolder(_:))
        case "trash":
            item.label = "Move to Trash"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Move to Trash")
            item.action = #selector(moveToTrash(_:))
        case "hidden":
            item.label = "Hidden Files"
            item.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hidden Files")
            item.action = #selector(toggleHiddenFiles(_:))
        default:
            return nil
        }
        item.target = self
        return item
    }
}


// MARK: - Open With menu

extension MainWindowController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.identifier?.rawValue == "servers" {
            populateServers(menu)
            return
        }
        guard let file = activePane.selectedItems.first?.url else {
            let empty = menu.addItem(withTitle: "No Selection", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }

        let applications = OpenWithMenu.applications(for: file)
        if applications.isEmpty {
            let empty = menu.addItem(withTitle: "No Applications", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for application in applications {
            let item = NSMenuItem(
                title: OpenWithMenu.displayName(for: application),
                action: #selector(openSelectionWith(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = application
            item.image = NSWorkspace.shared.icon(forFile: application.path)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let other = NSMenuItem(
            title: "Other…",
            action: #selector(chooseOpenWithApplication(_:)),
            keyEquivalent: ""
        )
        other.target = self
        menu.addItem(other)
    }

    private func populateServers(_ menu: NSMenu) {
        let bookmarks = bookmarkStore.load()
        if bookmarks.isEmpty {
            let empty = menu.addItem(withTitle: "No Saved Servers", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for bookmark in bookmarks {
            let item = NSMenuItem(
                title: bookmark.name,
                action: #selector(connectBookmark(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bookmark.id.uuidString
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let forget = NSMenuItem(
            title: "Forget Saved Servers…",
            action: #selector(forgetBookmarks(_:)),
            keyEquivalent: ""
        )
        forget.target = self
        menu.addItem(forget)
    }

    @objc private func openSelectionWith(_ sender: Any?) {
        guard let application = (sender as? NSMenuItem)?.representedObject as? URL,
              let file = activePane.selectedItems.first?.url else { return }
        OpenWithMenu.open(file, with: application)
    }

    @objc private func chooseOpenWithApplication(_ sender: Any?) {
        guard let file = activePane.selectedItems.first?.url else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose an application to open “\(file.lastPathComponent)”."
        panel.prompt = "Open"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let application = panel.url else { return }
            OpenWithMenu.open(file, with: application)
        }
    }
}


// MARK: - Toolbar validation

extension MainWindowController: NSToolbarItemValidation {
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let results = activePane.model.isSearchResults
        switch item.itemIdentifier.rawValue {
        case "back":
            return !results && activePane.model.canGoBack
        case "forward":
            return !results && activePane.model.canGoForward
        case "up":
            return !results && activePane.model.canGoUp
        case "newFolder":
            return !results && !activePane.model.isArchive
        case "trash":
            return !activePane.model.isArchive
        default:
            return true
        }
    }
}

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

    private var isSinglePane = false
    private var activePaneIndex = 0

    private var activeTabs: BrowserTabsViewController {
        activePaneIndex == 0 ? leftTabs : rightTabs
    }

    private var otherTabs: BrowserTabsViewController {
        activePaneIndex == 0 ? rightTabs : leftTabs
    }

    private var activePane: BrowserPaneViewController { activeTabs.activePane }
    private var otherPane: BrowserPaneViewController { otherTabs.activePane }

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

        configureSplitView(state: state)
        configurePanes()
        configureSidebar()
        configureToolbar()
        observeModels()
        updateWindowTitle()

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenInOtherPane(_:)),
            name: .openLiftOpenInOtherPane,
            object: nil
        )
    }

    private func configureSidebar() {
        sidebarViewController.onSelect = { [weak self] url in
            guard let self else { return }
            self.activePane.model.navigate(to: url)
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

    private func updateWindowTitle() {
        let name = activePane.model.directory.lastPathComponent
        window?.title = name.isEmpty ? "OpenLift" : name
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

    @objc public func goBack(_ sender: Any?) { activePane.model.goBack() }
    @objc public func goForward(_ sender: Any?) { activePane.model.goForward() }
    @objc public func goUp(_ sender: Any?) { activePane.model.goUp() }
    @objc public func goHome(_ sender: Any?) {
        activePane.model.navigate(to: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }
    @objc public func refresh(_ sender: Any?) { activePane.model.reload() }
    @objc public func openSelection(_ sender: Any?) { activePane.openSelection() }

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

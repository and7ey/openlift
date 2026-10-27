import AppKit
import OpenLiftCore

/// A pane that can hold several tabs.
///
/// Each tab is a full `BrowserPaneViewController` with its own model, history
/// and per-folder settings. Only the active pane is embedded in the container;
/// the others stay alive so their FSEvents watchers keep the listings warm.
@MainActor
public final class BrowserTabsViewController: NSViewController {
    public var onActivate: (() -> Void)?
    /// Forwarded from every pane in this tab container.
    public var onOperation: ((FileOperationRecord) -> Void)?

    private let provider: FileProvider
    private let settingsStore: ViewSettingsStore?
    private let tabBar = PaneTabBarView()
    private let container = NSView()
    public private(set) var panes: [BrowserPaneViewController] = []
    public private(set) var activeIndex = 0
    /// Last real folder shown in this container; new tabs use it while a
    /// search-results tab is active.
    private var lastBrowserDirectory = URL(fileURLWithPath: NSHomeDirectory())

    public init(
        provider: FileProvider,
        settingsStore: ViewSettingsStore?,
        initialTabs: [PaneState],
        activeTab: Int
    ) {
        self.provider = provider
        self.settingsStore = settingsStore
        super.init(nibName: nil, bundle: nil)

        let states = initialTabs.isEmpty ? [PaneState(path: NSHomeDirectory())] : initialTabs
        panes = states.map { state in
            let model = BrowserModel(
                provider: provider,
                directory: URL(fileURLWithPath: state.path, isDirectory: true),
                settings: state.settings,
                settingsStore: settingsStore
            )
            return makePane(model: model)
        }
        activeIndex = min(max(activeTab, 0), panes.count - 1)
        if let first = panes.first(where: { !$0.model.isSearchResults }) {
            lastBrowserDirectory = first.model.directory
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = NSView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(browserModelDidChange(_:)),
            name: .openLiftBrowserModelDidChange,
            object: nil
        )

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.selectTab(index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(index) }
        tabBar.onNew = { [weak self] in self?.newTab() }
        root.addSubview(tabBar)

        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        showActivePane()
    }

    // MARK: - Public API

    public var activePane: BrowserPaneViewController {
        panes[min(activeIndex, panes.count - 1)]
    }

    public var activeModel: BrowserModel {
        activePane.model
    }

    public func tabStates() -> [PaneState] {
        // Search results and remote sessions are session-only; a relaunch
        // restores real local folders.
        panes.filter { !$0.model.isSearchResults && !$0.model.isRemote }.map { pane in
            PaneState(
                path: pane.model.directory.path,
                backHistory: pane.model.backStack.map(\.path),
                forwardHistory: pane.model.forwardStack.map(\.path),
                settings: pane.model.settings
            )
        }
    }

    public func newTab(at url: URL? = nil) {
        let useFallback = activeModel.isSearchResults || activeModel.isRemote
        let directory = url ?? (useFallback ? lastBrowserDirectory : activeModel.directory)
        let model = BrowserModel(
            provider: provider,
            directory: directory,
            settings: activeModel.settings,
            settingsStore: settingsStore
        )
        panes.append(makePane(model: model))
        activeIndex = panes.count - 1
        showActivePane()
    }

    /// Opens a tab that lists a finished search's results.
    public func newSearchResultsTab(items: [FileItem]) {
        guard !items.isEmpty else { return }

        var settings = activeModel.settings
        settings.mode = .list
        settings.group = .none
        let directory = URL(
            string: "openlift-search:///Search%20Results%20(\(items.count))"
        )!
        let model = BrowserModel(
            provider: SearchResultsProvider(items: items),
            directory: directory,
            settings: settings,
            settingsStore: nil
        )
        panes.append(makePane(model: model))
        activeIndex = panes.count - 1
        showActivePane()
    }

    /// Opens a session tab backed by a remote provider.
    public func newRemoteTab(provider: FileProvider, directory: URL) {
        var settings = activeModel.settings
        settings.mode = .list
        settings.group = .none
        let model = BrowserModel(
            provider: provider,
            directory: directory,
            settings: settings,
            settingsStore: nil
        )
        panes.append(makePane(model: model))
        activeIndex = panes.count - 1
        showActivePane()
    }

    private func makePane(model: BrowserModel) -> BrowserPaneViewController {
        let pane = BrowserPaneViewController(model: model)
        pane.onActivate = { [weak self] in self?.onActivate?() }
        pane.onOperation = { [weak self] record in self?.onOperation?(record) }
        pane.onOpenSearchResultFolder = { [weak self] url in self?.newTab(at: url) }
        return pane
    }

    public func closeTab(_ index: Int) {
        guard panes.count > 1, index >= 0, index < panes.count else { return }

        let pane = panes[index]
        let wasActive = index == activeIndex
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        panes.remove(at: index)

        if index < activeIndex {
            activeIndex -= 1
        } else if wasActive {
            activeIndex = min(activeIndex, panes.count - 1)
        }
        activeIndex = min(max(activeIndex, 0), panes.count - 1)
        showActivePane()
    }

    public func closeActiveTab() {
        closeTab(activeIndex)
    }

    public func selectTab(_ index: Int) {
        guard index >= 0, index < panes.count, index != activeIndex else { return }
        activeIndex = index
        showActivePane()
    }

    public func selectNextTab() {
        guard panes.count > 1 else { return }
        selectTab((activeIndex + 1) % panes.count)
    }

    public func selectPreviousTab() {
        guard panes.count > 1 else { return }
        selectTab((activeIndex - 1 + panes.count) % panes.count)
    }

    // MARK: - Rendering

    private func showActivePane() {
        container.subviews.forEach { $0.removeFromSuperview() }

        let pane = activePane
        panes.forEach { $0.isActivePane = false }
        if !pane.model.isSearchResults {
            lastBrowserDirectory = pane.model.directory
        }
        if pane.parent == nil {
            addChild(pane)
        }
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: container.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        tabBar.update(titles: panes.map { tabTitle(for: $0) }, activeIndex: activeIndex)
        pane.activate()
        onActivate?()
    }

    private func tabTitle(for pane: BrowserPaneViewController) -> String {
        if pane.model.isRemote {
            return pane.model.fileProvider.displayName
        }
        let name = pane.model.directory.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    /// A tab's label follows its folder, so any navigation in any tab refreshes the strip.
    @objc private func browserModelDidChange(_ notification: Notification) {
        guard let model = notification.object as? BrowserModel,
              panes.contains(where: { $0.model === model }) else { return }
        tabBar.update(titles: panes.map { tabTitle(for: $0) }, activeIndex: activeIndex)
    }
}

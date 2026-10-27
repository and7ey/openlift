import Foundation

/// Observable state of one browser pane.
///
/// The model owns navigation history, the current listing, sorting and the
/// async load lifecycle. Views observe it through `onChange` so the same model
/// can back both the AppKit table and a future SwiftUI surface.
@MainActor
public final class BrowserModel {
    public private(set) var directory: URL
    public private(set) var items: [FileItem] = [] {
        didSet { invalidateDerivedCache() }
    }
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []

    public var settings: ViewSettings {
        didSet {
            guard oldValue != settings else { return }
            if !isApplyingStoredSettings {
                settingsStore?.set(settings, for: directory.path)
            }
            invalidateDerivedCache()
            if oldValue.showHidden != settings.showHidden, !suppressReload {
                reload()
            } else {
                notify()
            }
        }
    }

    /// Case-insensitive filter applied to the current folder. Set to an empty
    /// string to show everything.
    public var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            invalidateDerivedCache()
            notify()
        }
    }

    /// Called on the main actor whenever visible state changes.
    public var onChange: (() -> Void)?
    /// Called when a load fails, with a user-presentable error.
    public var onError: ((Error) -> Void)?

    private let provider: FileProvider
    private let settingsStore: ViewSettingsStore?
    private var loadTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var generation = 0
    private var isApplyingStoredSettings = false
    private var suppressReload = false
    /// Sorted/filtered and grouped views are expensive for large folders and
    /// are recomputed only when items, sorting or the query changes.
    private var displayCache: [FileItem]?
    private var groupCache: [(title: String, items: [FileItem])]?

    public init(
        provider: FileProvider,
        directory: URL,
        settings: ViewSettings = .default,
        settingsStore: ViewSettingsStore? = nil
    ) {
        self.provider = provider
        self.settingsStore = settingsStore
        self.directory = directory
        self.settings = settingsStore?.settings(for: directory.path) ?? settings
    }

    // MARK: - Derived state

    /// Items in display order, narrowed by `searchQuery` when it is set.
    public var displayItems: [FileItem] {
        if let displayCache { return displayCache }
        let sorted = FileItemOrdering.sorted(items, by: settings.sort)
        let filtered = FileItemOrdering.filtered(sorted, by: searchQuery)
        displayCache = filtered
        return filtered
    }

    /// Items grouped for sectioned presentation.
    public var groupedItems: [(title: String, items: [FileItem])] {
        if let groupCache { return groupCache }
        let grouped = FileItemOrdering.grouped(displayItems, by: settings.group)
        groupCache = grouped
        return grouped
    }

    private func invalidateDerivedCache() {
        displayCache = nil
        groupCache = nil
    }

    /// True when this pane shows a fixed search-result set instead of a folder.
    public var isSearchResults: Bool {
        provider.identifier == SearchResultsProvider.identifierValue
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var canGoUp: Bool { directory.path != "/" }

    public var totalSize: Int64 {
        items.reduce(0) { $0 + ($1.size ?? 0) }
    }

    // MARK: - Navigation

    public func navigate(to url: URL, addToHistory: Bool = true) {
        let standardized = url.standardizedFileURL
        guard standardized != directory else {
            reload()
            return
        }
        if addToHistory {
            backStack.append(directory)
            forwardStack.removeAll()
        }
        searchQuery = ""
        directory = standardized
        applyStoredSettings()
        items = []
        load()
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(directory)
        searchQuery = ""
        directory = previous
        applyStoredSettings()
        items = []
        load()
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(directory)
        searchQuery = ""
        directory = next
        applyStoredSettings()
        items = []
        load()
    }

    public func goUp() {
        guard canGoUp else { return }
        navigate(to: directory.deletingLastPathComponent())
    }

    public func reload() {
        load()
    }

    // MARK: - Mutation helpers

    public func applySort(_ key: SortKey, ascending: Bool? = nil) {
        var sort = settings.sort
        if sort.key == key {
            sort.ascending = ascending ?? !sort.ascending
        } else {
            sort.key = key
            sort.ascending = ascending ?? true
        }
        settings.sort = sort
    }

    // MARK: - Loading

    private func load() {
        loadTask?.cancel()
        generation += 1
        let currentGeneration = generation
        let target = directory
        let options = ListOptions(showHidden: settings.showHidden)
        let provider = self.provider

        isLoading = true
        lastError = nil
        ensureWatcher()
        notify()

        loadTask = Task { [weak self] in
            let result: Result<[FileItem], Error>
            do {
                let listed = try await provider.list(target, options: options)
                result = .success(listed)
            } catch {
                result = .failure(error)
            }

            guard !Task.isCancelled else { return }
            guard let self, self.generation == currentGeneration else { return }

            self.isLoading = false
            switch result {
            case .success(let listed):
                self.items = listed
                self.lastError = nil
            case .failure(let error):
                self.items = []
                self.lastError = error
                self.onError?(error)
            }
            self.notify()
        }
    }

    private func notify() {
        onChange?()
        NotificationCenter.default.post(name: .openLiftBrowserModelDidChange, object: self)
    }

    /// Applies the settings remembered for the current folder, if any.
    private func applyStoredSettings() {
        guard let stored = settingsStore?.settings(for: directory.path) else { return }
        suppressReload = true
        isApplyingStoredSettings = true
        settings = stored
        isApplyingStoredSettings = false
        suppressReload = false
    }

    /// Keeps a single FSEvents stream pointed at the current directory.
    private func ensureWatcher() {
        guard directory.isFileURL else {
            watcher?.stop()
            return
        }
        if watcher == nil {
            watcher = DirectoryWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reload()
                }
            }
        }
        watcher?.watch(directory)
    }
}

public extension Notification.Name {
    /// Posted on the main actor whenever a `BrowserModel` changes.
    static let openLiftBrowserModelDidChange = Notification.Name("OpenLiftBrowserModelDidChange")
}

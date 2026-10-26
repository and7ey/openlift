import Foundation

/// Observable state of one browser pane.
///
/// The model owns navigation history, the current listing, sorting and the
/// async load lifecycle. Views observe it through `onChange` so the same model
/// can back both the AppKit table and a future SwiftUI surface.
@MainActor
public final class BrowserModel {
    public private(set) var directory: URL
    public private(set) var items: [FileItem] = []
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []

    public var settings: ViewSettings {
        didSet {
            guard oldValue != settings else { return }
            if oldValue.showHidden != settings.showHidden {
                reload()
            } else {
                notify()
            }
        }
    }

    /// Called on the main actor whenever visible state changes.
    public var onChange: (() -> Void)?
    /// Called when a load fails, with a user-presentable error.
    public var onError: ((Error) -> Void)?

    private let provider: FileProvider
    private var loadTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var generation = 0

    public init(provider: FileProvider, directory: URL, settings: ViewSettings = .default) {
        self.provider = provider
        self.directory = directory
        self.settings = settings
    }

    // MARK: - Derived state

    /// Items in display order.
    public var displayItems: [FileItem] {
        FileItemOrdering.sorted(items, by: settings.sort)
    }

    /// Items grouped for sectioned presentation.
    public var groupedItems: [(title: String, items: [FileItem])] {
        FileItemOrdering.grouped(displayItems, by: settings.group)
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
        directory = standardized
        items = []
        load()
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(directory)
        directory = previous
        items = []
        load()
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(directory)
        directory = next
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

    /// Keeps a single FSEvents stream pointed at the current directory.
    private func ensureWatcher() {
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

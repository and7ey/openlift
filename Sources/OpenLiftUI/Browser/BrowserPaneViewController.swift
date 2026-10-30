import AppKit
import OpenLiftCore
import UniformTypeIdentifiers

/// One browser pane: path bar, list view and status bar.
///
/// The controller is intentionally AppKit-only. SwiftUI is reserved for
/// settings and auxiliary panels, where it is a better fit.
@MainActor
public final class BrowserPaneViewController: NSViewController {
    public let model: BrowserModel
    /// Whether this pane owns the cursor. The inactive pane hides its cursor
    /// completely, as classic two-pane managers do.
    public var isActivePane = false {
        didSet {
            guard isActivePane != oldValue else { return }
            refreshCursorAppearance()
            onActiveStateChanged?(isActivePane)
        }
    }
    /// Called when the pane gains or loses the cursor.
    public var onActiveStateChanged: ((Bool) -> Void)?

    /// Called when the pane becomes the active one (click, focus, navigation).
    public var onActivate: (() -> Void)?
    /// Called when the user opens a directory or file from this pane.
    public var onOpenDirectory: ((URL) -> Void)?
    /// Called when a folder in a search-results tab is opened; the container
    /// turns it into a new browser tab.
    public var onOpenSearchResultFolder: ((URL) -> Void)?
    /// Called with a reversible record after a mutating operation succeeds.
    public var onOperation: ((FileOperationRecord) -> Void)?

    private let pathControl = PathBarControl()
    private let remotePathLabel = NSTextField(labelWithString: "")
    private let searchOptionsButton = NSButton()
    private var pathHeight: NSLayoutConstraint?
    private let tableView = ActivatingTableView()
    private let scrollView = NSScrollView()
    private let iconScrollView = NSScrollView()
    private let collectionView = BrowserCollectionView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let operationBar = NSProgressIndicator()
    private let cancelButton = NSButton()
    private var operationBarHeight: NSLayoutConstraint?
    private var operationVerb = "Copying"
    private var operationProgressText: String?
    private var activeTransferToken: CancellationToken?
    private let searchField = NSSearchField()
    private var searchBarHeight: NSLayoutConstraint?
    private var searchVisible = false
    nonisolated(unsafe) private var searchKeyMonitor: Any?
    private var isRestoringSelection = false

    private var batchRenameController: BatchRenameWindowController?
    private var iconCache: [String: NSImage] = [:]
    /// Repository status for the current folder, refreshed off the main thread.
    private var gitSnapshot: GitSnapshot?
    private var gitRefreshToken = UUID()
    private var gitDirectory: URL?
    /// Color scheme for the list canvas; system by default.
    public private(set) var theme = Theme.system
    private var remoteTransfer: RemoteFileTransferring? {
        model.fileProvider as? RemoteFileTransferring
    }
    private var archiveProvider: ArchiveFileProvider? {
        model.fileProvider as? ArchiveFileProvider
    }
    /// Selection is remembered by URL so grouping/refresh re-selection is stable.
    private var selectedURLCache: Set<URL> = []
    /// Selection per visited folder, so going back returns the cursor to the
    /// folder that was used to enter the child.
    private var rememberedSelections: [URL: Set<URL>] = [:]
    private var lastListingDirectory: URL?
    /// Set when the pane enters a folder; cleared once a cursor is placed.
    private var pendingSelectionDirectory: URL?
    /// Recursive folder sizes calculated on demand, keyed by folder URL.
    private var folderSizes: [URL: Int64] = [:]
    private var pendingFolderSizes: Set<URL> = []
    private var folderSizeToken = UUID()
    /// Sorted rows and icon sections are built once per model change; building
    /// them inside cells would sort a 100k-item folder dozens of times.
    private var rowCache: [Row] = []
    private var iconSectionCache: [(title: String, items: [FileItem])] = [("", [])]

    public init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.reloadView() }
        model.onError = { [weak self] error in self?.presentListingError(error) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        configurePathControl()
        configureSearchOptionsButton()
        configureSearchField()
        configureTable()
        configureCollectionView()
        configureStatusBar()

        container.addSubview(pathControl)
        container.addSubview(remotePathLabel)
        container.addSubview(searchOptionsButton)
        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(iconScrollView)
        container.addSubview(operationBar)
        container.addSubview(cancelButton)
        container.addSubview(statusLabel)
        container.addSubview(progressIndicator)

        let operationBarHeight = operationBar.heightAnchor.constraint(equalToConstant: 0)
        self.operationBarHeight = operationBarHeight
        let searchBarHeight = searchField.heightAnchor.constraint(equalToConstant: 0)
        self.searchBarHeight = searchBarHeight
        let pathHeight = pathControl.heightAnchor.constraint(equalToConstant: 24)
        self.pathHeight = pathHeight

        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: searchOptionsButton.leadingAnchor, constant: -6),
            pathHeight,

            remotePathLabel.leadingAnchor.constraint(equalTo: pathControl.leadingAnchor),
            remotePathLabel.trailingAnchor.constraint(equalTo: searchOptionsButton.leadingAnchor, constant: -6),
            remotePathLabel.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),

            searchOptionsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchOptionsButton.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),
            searchOptionsButton.widthAnchor.constraint(equalToConstant: 22),
            searchOptionsButton.heightAnchor.constraint(equalToConstant: 22),

            searchField.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 2),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchBarHeight,

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 3),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: operationBar.topAnchor, constant: -2),

            iconScrollView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            iconScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iconScrollView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            operationBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            operationBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            operationBar.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),
            operationBarHeight,

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

            cancelButton.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            progressIndicator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            progressIndicator.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16)
        ])

        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        reloadView()
        model.reload()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
    }

    deinit {
        if let monitor = searchKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Configuration

    private func configurePathControl() {
        pathControl.url = model.directory
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        remotePathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        remotePathLabel.textColor = .secondaryLabelColor
        remotePathLabel.lineBreakMode = .byTruncatingMiddle
        remotePathLabel.isHidden = true
        remotePathLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSearchOptionsButton() {
        searchOptionsButton.bezelStyle = .inline
        searchOptionsButton.isBordered = false
        searchOptionsButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Search options"
        )
        searchOptionsButton.toolTip = "Search options"
        searchOptionsButton.target = self
        searchOptionsButton.action = #selector(showSearchOptions(_:))
        searchOptionsButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSearchField() {
        searchField.placeholderString = "Search in “\(model.directory.lastPathComponent)”"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 104)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        layout.headerReferenceSize = NSSize(width: 0, height: 26)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [NSColor.clear]
        collectionView.register(
            IconItemView.self,
            forItemWithIdentifier: IconItemView.identifier
        )
        collectionView.register(
            IconSectionHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: IconSectionHeader.identifier
        )
        collectionView.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL])
        collectionView.menu = makeContextMenu()
        collectionView.onActivate = { [weak self] in self?.activate() }
        collectionView.onQuickLook = { [weak self] in self?.performQuickLook() }

        let doubleClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(collectionDoubleClicked(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        iconScrollView.documentView = collectionView
        iconScrollView.hasVerticalScroller = true
        iconScrollView.autohidesScrollers = true
        iconScrollView.drawsBackground = false
        iconScrollView.isHidden = model.settings.mode != .icon
        iconScrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = model.settings.mode == .icon
    }

    private func configureTable() {
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onActivate = { [weak self] in self?.activate() }
        tableView.onQuickLook = { [weak self] in self?.performQuickLook() }
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.menu = makeContextMenu()
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.sortDescriptors = [NSSortDescriptor(key: model.settings.sort.key.rawValue, ascending: model.settings.sort.ascending)]

        addColumn(id: "name", title: "Name", width: 260)
        addColumn(id: "path", title: "Path", width: 300, sortable: false)
        addColumn(id: "size", title: "Size", width: 80, alignment: .right)
        addColumn(id: "kind", title: "Kind", width: 130)
        addColumn(id: "modified", title: "Date Modified", width: 160)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
    }

    private func addColumn(
        id: String,
        title: String,
        width: CGFloat,
        alignment: NSTextAlignment = .left,
        sortable: Bool = true
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = 50
        column.headerCell.alignment = alignment
        column.isHidden = id == "path"
        if sortable {
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        }
        tableView.addTableColumn(column)
    }

    private func configureStatusBar() {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        operationBar.style = .bar
        operationBar.isIndeterminate = false
        operationBar.minValue = 0
        operationBar.maxValue = 100
        operationBar.doubleValue = 0
        operationBar.isHidden = true
        operationBar.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTransfer(_:))
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection), keyEquivalent: "")
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let openWithMenu = NSMenu(title: "Open With")
        openWithMenu.delegate = self
        openWithItem.submenu = openWithMenu
        menu.addItem(openWithItem)
        menu.addItem(withTitle: "Edit", action: #selector(editSelectionAction), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Other Pane", action: #selector(openInOtherPane), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quick Look", action: #selector(quickLookAction), keyEquivalent: "")
        menu.addItem(withTitle: "Get Info", action: #selector(getInfoAction), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPathAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Folder", action: #selector(newFolderAction), keyEquivalent: "")
        menu.addItem(withTitle: "Rename…", action: #selector(renameAction), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateAction), keyEquivalent: "")
        menu.addItem(withTitle: "Batch Rename…", action: #selector(batchRenameAction), keyEquivalent: "")
        menu.addItem(withTitle: "Compress", action: #selector(compressAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrashAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinderAction), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminalAction), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: - Rendering

    private enum Row {
        case group(String)
        case item(FileItem)
    }

    private var rows: [Row] { rowCache }

    private func makeRows() -> [Row] {
        guard model.settings.group != .none else {
            return model.displayItems.map(Row.item)
        }
        return model.groupedItems.flatMap { group -> [Row] in
            [.group(group.title)] + group.items.map(Row.item)
        }
    }

    private func makeIconSections() -> [(title: String, items: [FileItem])] {
        if model.settings.group == .none {
            return [("", model.displayItems)]
        }
        return model.groupedItems.map { ($0.title, $0.items) }
    }

    private func reloadView() {
        let resultsMode = model.isSearchResults
        let virtualLocation = model.isRemote || model.isArchive
        pathHeight?.constant = resultsMode ? 0 : 24
        pathControl.isHidden = resultsMode || virtualLocation
        remotePathLabel.isHidden = !virtualLocation
        if model.isRemote {
            remotePathLabel.stringValue = model.directory.absoluteString
            remotePathLabel.toolTip = model.directory.absoluteString
        } else if model.isArchive, let archiveProvider {
            let relative = archiveProvider.relativePath(for: model.directory)
            let text = relative.isEmpty
                ? archiveProvider.displayName
                : "\(archiveProvider.displayName) / \(relative)"
            remotePathLabel.stringValue = text
            remotePathLabel.toolTip = text
        }
        searchOptionsButton.isHidden = resultsMode || virtualLocation
        if !resultsMode, !model.isRemote {
            pathControl.url = model.directory
        }
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("path"))?.isHidden = !resultsMode
        searchField.placeholderString = "Search in “\(model.directory.lastPathComponent)”"
        if model.searchQuery.isEmpty, searchField.currentEditor() == nil {
            searchField.stringValue = ""
        }

        let directoryChanged = lastListingDirectory != model.directory
        if directoryChanged {
            if let previous = lastListingDirectory {
                rememberedSelections[previous] = selectedURLCache
            }
            lastListingDirectory = model.directory
            pendingSelectionDirectory = model.directory
        }

        rowCache = makeRows()
        iconSectionCache = makeIconSections()

        let iconMode = model.settings.mode == .icon
        scrollView.isHidden = iconMode
        iconScrollView.isHidden = !iconMode

        tableView.reloadData()
        collectionView.reloadData()

        var selection: Set<URL> = []
        var shouldScroll = directoryChanged
        if pendingSelectionDirectory == model.directory {
            let items = model.displayItems
            if !items.isEmpty {
                let available = Set(items.map(\.url))
                let remembered = rememberedSelections[model.directory]?
                    .intersection(available) ?? []
                if remembered.isEmpty {
                    selection = items.first.map { [$0.url] } ?? []
                } else {
                    selection = remembered
                }
                pendingSelectionDirectory = nil
                shouldScroll = true
            }
        } else {
            selection = selectedURLCache
        }
        applySelection(selection, scroll: shouldScroll)

        if gitDirectory != model.directory {
            gitDirectory = model.directory
            gitSnapshot = nil
        }
        updateStatus()
        updateProgress()
        syncSortDescriptors()
        refreshGitStatus()
    }

    /// Applies one selection to both list and icon views. Remembering the URLs
    /// keeps the cursor stable across refreshes, sorting and view-mode changes.
    private func applySelection(_ urls: Set<URL>, scroll: Bool) {
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        selectedURLCache = urls

        var indexes = IndexSet()
        var firstRow: Int?
        for (index, row) in rows.enumerated() {
            if case .item(let item) = row, urls.contains(item.url) {
                indexes.insert(index)
                if firstRow == nil { firstRow = index }
            }
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let firstRow {
            tableView.scrollRowToVisible(firstRow)
        }

        var paths = Set<IndexPath>()
        var firstPath: IndexPath?
        for (section, group) in iconSections.enumerated() {
            for (index, item) in group.items.enumerated() where urls.contains(item.url) {
                let path = IndexPath(item: index, section: section)
                paths.insert(path)
                if firstPath == nil { firstPath = path }
            }
        }
        collectionView.selectItems(at: paths, scrollPosition: [])
        if scroll, let firstPath {
            collectionView.scrollToItems(at: [firstPath], scrollPosition: .nearestHorizontalEdge)
        }
    }

    // MARK: - Folder sizes

    /// Calculates recursive sizes for the selected folders, or for every
    /// folder in the listing when nothing is selected.
    public func calculateFolderSizes() {
        guard model.directory.isFileURL,
              !model.isRemote,
              !model.isArchive,
              !model.isSearchResults else {
            NSSound.beep()
            return
        }

        let selection = selectedItems
        let folders: [FileItem]
        if selection.isEmpty {
            folders = model.displayItems.filter(\.isDirectory)
        } else {
            folders = selection.filter(\.isDirectory)
        }
        guard !folders.isEmpty else {
            NSSound.beep()
            return
        }

        let urls = folders.map(\.url)
        let token = UUID()
        folderSizeToken = token
        pendingFolderSizes.removeAll()
        for url in urls {
            folderSizes.removeValue(forKey: url)
            pendingFolderSizes.insert(url)
        }
        reloadRows(containing: Set(urls))
        updateStatus()

        Task { [weak self] in
            guard let self else { return }
            for url in urls {
                let size = await FolderSizer.size(of: url)
                guard self.folderSizeToken == token else { return }
                self.pendingFolderSizes.remove(url)
                if let size {
                    self.folderSizes[url] = size
                }
                self.reloadRows(containing: [url])
            }
            self.updateStatus()
        }
    }

    private func reloadRows(containing urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        var indexes = IndexSet()
        for (index, row) in rows.enumerated() {
            if case .item(let item) = row, urls.contains(item.url) {
                indexes.insert(index)
            }
        }
        guard !indexes.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: indexes,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    // MARK: - Appearance

    /// Applies the theme's row colors. Window appearance is set once by the
    /// window controller, so every pane and sheet follows it together.
    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        let background = theme.backgroundColor ?? .controlBackgroundColor
        tableView.backgroundColor = background
        scrollView.backgroundColor = background
        tableView.usesAlternatingRowBackgroundColors = theme.alternateBackground == nil
        iconScrollView.backgroundColor = background
        collectionView.backgroundColors = [background]
        tableView.reloadData()
        collectionView.reloadData()
    }

    // MARK: - Git

    public var currentGitSnapshot: GitSnapshot? { gitSnapshot }

    /// Repository-relative paths for the selected items, used by Git commands.
    public func repositoryRelativePaths(for items: [FileItem]) -> [String] {
        guard let snapshot = gitSnapshot else { return [] }
        return items.compactMap { snapshot.relativePath(of: $0.url) }.filter { !$0.isEmpty }
    }

    public func gitStatus(for item: FileItem) -> GitStatusEntry? {
        guard let snapshot = gitSnapshot,
              let path = snapshot.relativePath(of: item.url) else { return nil }
        return snapshot.status(forPath: path)
    }

    /// Re-reads `git status` for the current folder. Safe to call after any
    /// change; stale results are dropped by the token check.
    public func refreshGitStatus() {
        guard model.directory.isFileURL,
              !model.isRemote,
              !model.isArchive,
              !model.isSearchResults else {
            if gitSnapshot != nil {
                gitSnapshot = nil
                reloadRowsPreservingSelection()
            }
            return
        }
        let directory = model.directory
        let token = UUID()
        gitRefreshToken = token
        Task { [weak self] in
            let root = await GitClient.repositoryRoot(containing: directory)
            var snapshot: GitSnapshot?
            if let root {
                snapshot = try? await GitClient.snapshot(at: root)
            }
            guard let self, self.gitRefreshToken == token else { return }
            self.gitSnapshot = snapshot
            self.reloadRowsPreservingSelection()
        }
    }

    /// Reloads the badge-bearing cells without losing the cursor.
    private func reloadRowsPreservingSelection() {
        let selection = selectedURLCache
        tableView.reloadData()
        if model.settings.mode == .icon {
            collectionView.reloadData()
        }
        applySelection(selection, scroll: false)
        updateStatus()
    }

    private func gitBadgeColor(for entry: GitStatusEntry) -> NSColor {
        if entry.isAggregate { return .tertiaryLabelColor }
        if entry.isConflicted { return .systemRed }
        if entry.isUntracked { return .systemGreen }
        if entry.hasUnstagedChanges { return .systemOrange }
        return .systemBlue
    }

    /// Sections shown by the icon view: grouping applies there too.
    private var iconSections: [(title: String, items: [FileItem])] { iconSectionCache }

    private func updateProgress() {
        if model.isLoading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func updateStatus() {
        if let operationProgressText {
            statusLabel.stringValue = operationProgressText
            return
        }
        let resultsMode = model.isSearchResults
        let count = model.displayItems.count
        let selected = model.settings.mode == .icon
            ? collectionView.selectionIndexPaths.count
            : tableView.selectedRowIndexes.count
        var text: String
        if resultsMode {
            text = count == 1 ? "1 result" : "\(Self.number(count)) results"
        } else if model.searchQuery.isEmpty {
            text = Self.itemCountText(count)
        } else {
            text = "\(Self.number(count)) of \(Self.number(model.items.count)) items"
        }
        if selected > 0, !resultsMode {
            text = "\(Self.number(selected)) of \(Self.number(count)) selected"
            if let size = selectedSizeText() {
                text += " (\(size))"
            }
        } else if selected > 0 {
            text += ", \(Self.number(selected)) selected"
        }
        if let gitSnapshot, !resultsMode {
            text = "\(gitSnapshot.summaryText) — " + text
        }
        if let free = availableCapacity() {
            text += ", \(Formatting.size(free)) available"
        }
        statusLabel.stringValue = text
    }

    /// Combined size of the selection, as shown in parentheses in the status
    /// bar. Folder sizes count once calculated with Calculate Folder Size.
    private func selectedSizeText() -> String? {
        let items = selectedItems
        guard !items.isEmpty else { return nil }
        var total: Int64 = 0
        var known = false
        for item in items {
            if item.isDirectory {
                if let size = folderSizes[item.url] {
                    total += size
                    known = true
                }
            } else if let size = item.size {
                total += size
                known = true
            }
        }
        guard known else { return nil }
        return Formatting.size(total)
    }

    private static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private static func itemCountText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(number(count)) items"
    }

    private func availableCapacity() -> Int64? {
        guard model.directory.isFileURL else { return nil }
        let values = try? model.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func syncSortDescriptors() {
        let descriptor = NSSortDescriptor(
            key: model.settings.sort.key.rawValue,
            ascending: model.settings.sort.ascending
        )
        if tableView.sortDescriptors.first != descriptor {
            tableView.sortDescriptors = [descriptor]
        }
    }

    private func icon(for item: FileItem) -> NSImage {
        let key = item.contentTypeIdentifier ?? (item.isDirectory ? "folder" : "file")
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if item.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if let type = item.contentTypeIdentifier.flatMap(UTType.init) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }

    private func presentListingError(_ error: Error) {
        present(error: error, title: "Can’t open folder")
    }

    private func present(error: Error) {
        present(error: error, title: "The operation failed")
    }

    /// Shows an alert; permission failures offer a jump to Full Disk Access.
    private func present(error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")

        if Self.isPermissionDenied(error) {
            alert.messageText = "Permission denied"
            alert.informativeText = error.localizedDescription +
                "\n\nIf this folder is protected, grant OpenLift access in System Settings ▸ " +
                "Privacy & Security ▸ Full Disk Access, then try again."
            alert.buttons.first?.title = "Open System Settings"
            alert.addButton(withTitle: "Cancel")

            let openSettings = {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            if let window = view.window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { openSettings() }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
            return
        }

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        if let providerError = error as? FileProviderError, case .permissionDenied = providerError {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EPERM) || nsError.code == Int(EACCES)
        }
        return false
    }

    // MARK: - Selection

    public var selectedItems: [FileItem] {
        if model.settings.mode == .icon {
            let sections = iconSections
            return collectionView.selectionIndexPaths.sorted().compactMap { indexPath -> FileItem? in
                guard indexPath.section < sections.count,
                      indexPath.item < sections[indexPath.section].items.count else { return nil }
                return sections[indexPath.section].items[indexPath.item]
            }
        }
        let rows = self.rows
        return tableView.selectedRowIndexes.compactMap { index in
            guard index < rows.count, case .item(let item) = rows[index] else { return nil }
            return item
        }
    }

    public var focusedItem: FileItem? {
        if model.settings.mode == .icon {
            return selectedItems.first
        }
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : tableView.clickedRow
        let rows = self.rows
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return nil }
        return item
    }

    public func activate() {
        isActivePane = true
        view.window?.makeFirstResponder(model.settings.mode == .icon ? collectionView : tableView)
        onActivate?()
    }

    public func deactivate() {
        isActivePane = false
    }

    /// Redraws the cursor after the pane becomes active or inactive. Row views
    /// consult `showsSelection`; reloading the selected rows restores the
    /// emphasized text color AppKit drops while the cursor is hidden.
    private func refreshCursorAppearance() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? ThemedRowView)?.showsSelection = self.isActivePane
            rowView.needsDisplay = true
        }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let visibleSelected = tableView.selectedRowIndexes.intersection(
            IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length))
        )
        if !visibleSelected.isEmpty {
            tableView.reloadData(
                forRowIndexes: visibleSelected,
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }
        // Icons keep their selection; only the highlight follows the pane.
        for case let tile as IconItemView in collectionView.visibleItems() {
            tile.hidesSelection = !isActivePane
        }
    }

    // MARK: - Actions

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        activate()
        guard let url = sender.clickedPathItem?.url else { return }
        model.navigate(to: url)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        activate()
        openSelection()
    }

    @objc private func collectionDoubleClicked(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
           !collectionView.selectionIndexPaths.contains(indexPath) {
            collectionView.selectionIndexPaths = [indexPath]
            selectedURLCache = Set(selectedItems.map(\.url))
        }
        activate()
        openSelection()
    }

    @objc public func openSelection() {
        guard let item = focusedItem else { return }
        if model.isRemote {
            if item.isBrowsableDirectory {
                model.navigate(to: item.url)
            } else {
                openRemoteItem(item)
            }
            return
        }
        if model.isArchive {
            if item.isBrowsableDirectory {
                model.navigate(to: item.url)
            } else {
                openArchiveItem(item)
            }
            return
        }
        if ArchiveFormat.detect(item.url) != nil, model.directory.isFileURL {
            NotificationCenter.default.post(
                name: .openLiftOpenArchive,
                object: self,
                userInfo: ["url": item.url]
            )
            return
        }
        if item.isBrowsableDirectory {
            if model.isSearchResults {
                onOpenSearchResultFolder?(item.url)
            } else {
                model.navigate(to: item.url)
                onOpenDirectory?(item.url)
            }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func showSearchOptions(_ sender: NSButton) {
        let menu = NSMenu()

        let filter = NSMenuItem(
            title: "Filter in This Folder",
            action: #selector(filterFromMenu(_:)),
            keyEquivalent: ""
        )
        filter.target = self
        menu.addItem(filter)
        menu.addItem(.separator())

        let here = NSMenuItem(
            title: "Search in This Folder…",
            action: #selector(searchHereFromMenu(_:)),
            keyEquivalent: ""
        )
        here.target = self
        menu.addItem(here)

        let recursive = NSMenuItem(
            title: "Search Recursively…",
            action: #selector(searchRecursivelyFromMenu(_:)),
            keyEquivalent: ""
        )
        recursive.target = self
        menu.addItem(recursive)

        let content = NSMenuItem(
            title: "Search File Contents…",
            action: #selector(searchContentsFromMenu(_:)),
            keyEquivalent: ""
        )
        content.target = self
        menu.addItem(content)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    @objc private func filterFromMenu(_ sender: Any?) {
        beginSearch()
    }

    @objc private func searchHereFromMenu(_ sender: Any?) {
        startAdvancedSearch(recursive: false, focusContent: false)
    }

    @objc private func searchRecursivelyFromMenu(_ sender: Any?) {
        startAdvancedSearch(recursive: true, focusContent: false)
    }

    @objc private func searchContentsFromMenu(_ sender: Any?) {
        startAdvancedSearch(recursive: true, focusContent: true)
    }

    private func startAdvancedSearch(recursive: Bool, focusContent: Bool) {
        guard !model.isSearchResults, !model.isRemote, !model.isArchive else { return }
        NotificationCenter.default.post(
            name: .openLiftAdvancedSearch,
            object: self,
            userInfo: [
                "root": model.directory,
                "recursive": recursive,
                "focusContent": focusContent
            ]
        )
    }

    /// Reveals the in-folder search field, or closes it when already open.
    public func beginSearch() {
        if searchVisible {
            endSearch()
            return
        }
        searchField.placeholderString = "Search in “\(model.directory.lastPathComponent)”"
        searchVisible = true
        searchField.isHidden = false
        searchBarHeight?.constant = 24

        // The field editor consumes Escape before it reaches the pane, so the
        // search bar gets its own local monitor while it is open.
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.endSearch()
            return nil
        }

        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Hides the search field and restores the full listing.
    public func endSearch() {
        guard searchVisible || !model.searchQuery.isEmpty else { return }
        searchVisible = false
        if let monitor = searchKeyMonitor {
            NSEvent.removeMonitor(monitor)
            searchKeyMonitor = nil
        }
        searchField.stringValue = ""
        searchBarHeight?.constant = 0
        searchField.isHidden = true
        model.searchQuery = ""
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        model.searchQuery = sender.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// Shows (or dismisses) Quick Look for the current selection.
    public func performQuickLook() {
        if model.isRemote {
            quickLookRemoteSelection()
            return
        }
        if model.isArchive {
            quickLookArchiveSelection()
            return
        }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.present(urls)
    }

    private func openRemoteItem(_ item: FileItem) {
        guard let transfer = remoteTransfer else { NSSound.beep(); return }
        let target = remoteCacheURL(for: item)
        Task { [weak self] in
            do {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try await transfer.download(item.url, to: target)
                }
                NSWorkspace.shared.open(target)
            } catch {
                self?.present(error: error)
            }
        }
    }

    private func quickLookRemoteSelection() {
        guard let transfer = remoteTransfer else { NSSound.beep(); return }
        let files = selectedItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { NSSound.beep(); return }

        Task { [weak self] in
            guard let self else { return }
            var localURLs: [URL] = []
            for item in files {
                let target = self.remoteCacheURL(for: item)
                do {
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try await transfer.download(item.url, to: target)
                    }
                    localURLs.append(target)
                } catch {
                    self.present(error: error)
                }
            }
            if !localURLs.isEmpty {
                QuickLookController.shared.present(localURLs)
            }
        }
    }

    private func archiveCacheURL(for item: FileItem) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let archiveName = (archiveProvider?.archiveURL.lastPathComponent ?? "archive")
            .replacingOccurrences(of: "/", with: "_")
        let relative = archiveProvider?.relativePath(for: item.url) ?? item.name
        var url = base
            .appendingPathComponent("OpenLift", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(archiveName, isDirectory: true)
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }

    private func openArchiveItem(_ item: FileItem) {
        guard let provider = archiveProvider else { NSSound.beep(); return }
        let target = archiveCacheURL(for: item)
        let relative = provider.relativePath(for: item.url)
        Task { [weak self] in
            do {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try await provider.extract(relative, to: target)
                }
                NSWorkspace.shared.open(target)
            } catch {
                self?.present(error: error)
            }
        }
    }

    private func quickLookArchiveSelection() {
        guard let provider = archiveProvider else { NSSound.beep(); return }
        let files = selectedItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { NSSound.beep(); return }

        Task { [weak self] in
            guard let self else { return }
            var localURLs: [URL] = []
            for item in files {
                let target = self.archiveCacheURL(for: item)
                do {
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try await provider.extract(provider.relativePath(for: item.url), to: target)
                    }
                    localURLs.append(target)
                } catch {
                    self.present(error: error)
                }
            }
            if !localURLs.isEmpty {
                QuickLookController.shared.present(localURLs)
            }
        }
    }

    private func remoteCacheURL(for item: FileItem) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let host = (model.directory.host ?? "remote").replacingOccurrences(of: "/", with: "_")
        var url = base
            .appendingPathComponent("OpenLift", isDirectory: true)
            .appendingPathComponent("Remote", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
        for component in item.url.pathComponents where component != "/" && component != "." && component != ".." {
            url.appendPathComponent(component)
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }

    @objc func quickLookAction() {
        performQuickLook()
    }

    /// Opens the selected files in the configured editor (TextEdit by default).
    public func editSelection() {
        guard !model.isRemote, !model.isArchive else {
            NSSound.beep()
            return
        }
        let files = selectedItems.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }
        let editorPath = EditorStore.shared.resolvedApplicationPath
        guard FileManager.default.fileExists(atPath: editorPath) else {
            present(
                error: NSError(
                    domain: "dev.openlift.editor",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The configured editor “\(EditorStore.shared.displayName)” could not be found."
                    ]
                ),
                title: "Could not edit the selection"
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            files.map(\.url),
            withApplicationAt: URL(fileURLWithPath: editorPath),
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.present(error: error, title: "Could not open the editor")
            }
        }
    }

    @objc func editSelectionAction() {
        editSelection()
    }

    @objc func copyPathAction() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let text = items.map { $0.url.path }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func getInfoAction() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(
            name: .openLiftGetInfo,
            object: self,
            userInfo: ["urls": urls]
        )
    }

    @objc func openWithApplication(_ sender: Any?) {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        guard let application = (sender as? NSMenuItem)?.representedObject as? URL,
              let url = focusedItem?.url else { return }
        OpenWithMenu.open(url, with: application)
    }

    @objc func chooseOpenWithApplication(_ sender: Any?) {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        guard let url = focusedItem?.url else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose an application to open “\(url.lastPathComponent)”."
        panel.prompt = "Open"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let application = panel.url else { return }
            OpenWithMenu.open(url, with: application)
        }
    }

    @objc func openInOtherPane() {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        guard let item = focusedItem else { return }
        NotificationCenter.default.post(
            name: .openLiftOpenInOtherPane,
            object: self,
            userInfo: ["url": item.isBrowsableDirectory ? item.url : item.url.deletingLastPathComponent()]
        )
    }

    @objc func newFolderAction() {
        guard !model.isSearchResults, !model.isArchive else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "untitled folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = model.directory.appendingPathComponent(name, isDirectory: true)
        let provider: FileProvider = model.isRemote ? model.fileProvider : LocalFileProvider()
        let recordsUndo = !model.isRemote
        let activityID = ActivityLog.shared.begin(title: "New Folder", detail: destination.absoluteString)
        Task {
            do {
                try await provider.createDirectory(at: destination)
                if recordsUndo {
                    onOperation?(
                        FileOperationRecord(
                            kind: .createDirectory,
                            pairs: [.init(source: destination, target: destination)]
                        )
                    )
                }
                ActivityLog.shared.finish(activityID, status: .completed)
                model.reload()
            } catch {
                ActivityLog.shared.finish(activityID, status: .failed, message: error.localizedDescription)
                present(error: error)
            }
        }
    }

    @objc func renameAction() {
        guard !model.isArchive else { NSSound.beep(); return }
        guard let item = focusedItem else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        let provider: FileProvider = model.isRemote ? model.fileProvider : LocalFileProvider()
        let record = FileOperationRecord(kind: .rename, pairs: [.init(source: item.url, target: destination)])
        let recordsUndo = !model.isRemote
        let activityID = ActivityLog.shared.begin(title: record.title, detail: "to “\(newName)”")
        Task {
            do {
                try await provider.move(item.url, to: destination)
                if recordsUndo {
                    onOperation?(record)
                }
                ActivityLog.shared.finish(activityID, status: .completed)
                model.reload()
            } catch {
                ActivityLog.shared.finish(activityID, status: .failed, message: error.localizedDescription)
                present(error: error)
            }
        }
    }

    /// Opens the batch rename sheet for the current selection.
    public func performBatchRename() {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        let controller = BatchRenameWindowController(urls: urls)
        batchRenameController = controller
        controller.onApply = { [weak self] pairs in
            guard let self, !pairs.isEmpty else { return }
            self.onOperation?(FileOperationRecord(kind: .rename, pairs: pairs))

            let title = pairs.count == 1
                ? "Batch Rename “\(pairs[0].source.lastPathComponent)”"
                : "Batch Rename \(pairs.count) items"
            let id = ActivityLog.shared.begin(title: title, detail: "\(pairs.count) items")
            ActivityLog.shared.finish(id, status: .completed)
            self.model.reload()
        }
        controller.onDismiss = { [weak self] in
            self?.batchRenameController = nil
        }
        controller.present(on: view.window)
    }

    @objc func batchRenameAction() {
        performBatchRename()
    }

    @objc func duplicateAction() {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let provider = LocalFileProvider()
        let items = selectedItems
        guard !items.isEmpty else { return }

        let planned = items.map { ($0.url, Self.uniqueDestination(for: $0.url)) }
        let record = FileOperationRecord(
            kind: .copy,
            pairs: planned.map { .init(source: $0.0, target: $0.1) }
        )
        let activityID = ActivityLog.shared.begin(
            title: record.title,
            detail: "\(planned.count) item\(planned.count == 1 ? "" : "s") in place"
        )

        Task {
            var copied: [FileOperationRecord.Pair] = []
            var failures: [String] = []
            for (source, destination) in planned {
                do {
                    try await provider.copy(source, to: destination)
                    copied.append(.init(source: source, target: destination))
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                    present(error: error)
                }
            }
            if !copied.isEmpty {
                onOperation?(FileOperationRecord(kind: .copy, pairs: copied))
            }
            ActivityLog.shared.finish(
                activityID,
                status: failures.isEmpty ? .completed : .failed,
                message: failures.first
            )
            model.reload()
        }
    }

    /// Compresses the selection into a ZIP next to it.
    public func compressSelection() {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        let destination = ArchiveCreator.destination(for: sources, in: model.directory)
        let title = sources.count == 1
            ? "Compress “\(sources[0].lastPathComponent)”"
            : "Compress \(sources.count) items"
        let activityID = ActivityLog.shared.begin(
            title: title,
            detail: "\(sources.count) item\(sources.count == 1 ? "" : "s") → “\(destination.lastPathComponent)”"
        )

        Task {
            do {
                _ = try await ArchiveCreator().createArchive(containing: sources, to: destination)
                ActivityLog.shared.finish(activityID, status: .completed)
                model.reload()
            } catch {
                ActivityLog.shared.finish(activityID, status: .failed, message: error.localizedDescription)
                present(error: error)
            }
        }
    }

    @objc func compressAction() {
        compressSelection()
    }

    @objc func moveToTrashAction() {
        guard !model.isArchive else { NSSound.beep(); return }
        let items = selectedItems
        guard !items.isEmpty else { return }

        if model.isRemote {
            deleteRemoteSelection(items)
            return
        }
        guard confirmTrash(items) else { return }
        let provider = LocalFileProvider()

        let title = FileOperationRecord(
            kind: .trash,
            pairs: items.map { .init(source: $0.url, target: $0.url) }
        ).title
        let detail = items.count == 1
            ? items[0].url.deletingLastPathComponent().path
            : "\(items.count) items"
        let activityID = ActivityLog.shared.begin(title: title, detail: detail)

        Task {
            var pairs: [FileOperationRecord.Pair] = []
            var failures: [String] = []
            for item in items {
                do {
                    let trashed = try await provider.trash(item.url)
                    pairs.append(.init(source: item.url, target: trashed))
                } catch {
                    failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                    present(error: error)
                }
            }
            if !pairs.isEmpty {
                onOperation?(FileOperationRecord(kind: .trash, pairs: pairs))
            }
            ActivityLog.shared.finish(
                activityID,
                status: failures.isEmpty ? .completed : .failed,
                message: failures.first
            )
            model.reload()
        }
    }

    /// Moves require explicit confirmation: trashing from a two-pane manager is
    /// easy to trigger by accident.
    private func confirmTrash(_ items: [FileItem]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "Move “\(items[0].name)” to the Trash?"
            : "Move \(items.count) items to the Trash?"
        alert.informativeText = "You can restore deleted items from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func deleteRemoteSelection(_ items: [FileItem]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "Delete “\(items[0].name)” permanently?"
            : "Delete \(items.count) items permanently?"
        alert.informativeText = "Remote items do not use the local Trash and cannot be restored."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let provider = model.fileProvider
        let title = items.count == 1 ? "Delete “\(items[0].name)”" : "Delete \(items.count) remote items"
        let activityID = ActivityLog.shared.begin(title: title, detail: model.directory.absoluteString)

        Task { [weak self] in
            var failures: [String] = []
            for item in items {
                do {
                    try await provider.delete(item.url)
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
            ActivityLog.shared.finish(
                activityID,
                status: failures.isEmpty ? .completed : .failed,
                message: failures.first
            )
            if let first = failures.first {
                self?.presentMessage(
                    title: failures.count == 1 ? "An item could not be deleted" : "\(failures.count) items could not be deleted",
                    message: first
                )
            }
            self?.model.reload()
        }
    }

    /// Uploads local files/folders into `directory` on this remote pane.
    public func uploadSelection(_ sources: [URL], to directory: URL? = nil) {
        guard model.isRemote, let transfer = remoteTransfer else {
            NSSound.beep()
            return
        }
        let destination = directory ?? model.directory
        guard !sources.isEmpty else { return }

        let title = sources.count == 1
            ? "Upload “\(sources[0].lastPathComponent)”"
            : "Upload \(sources.count) items"
        let activityID = ActivityLog.shared.begin(title: title, detail: destination.absoluteString)

        Task { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for source in sources {
                do {
                    let target = try await self.uniqueRemoteDestination(
                        named: source.lastPathComponent,
                        in: destination
                    )
                    try await self.uploadLocalItem(source, to: target, using: transfer)
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            ActivityLog.shared.finish(
                activityID,
                status: failures.isEmpty ? .completed : .failed,
                message: failures.first
            )
            if let first = failures.first {
                self.presentMessage(
                    title: failures.count == 1 ? "An item could not be uploaded" : "\(failures.count) items failed",
                    message: first
                )
            }
            self.model.reload()
        }
    }

    private func uploadLocalItem(
        _ source: URL,
        to target: URL,
        using transfer: RemoteFileTransferring
    ) async throws {
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            do {
                try await model.fileProvider.createDirectory(at: target)
            } catch {
                // Merging into an existing folder is fine; keep walking it.
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            for child in children {
                try await uploadLocalItem(
                    child,
                    to: target.appendingPathComponent(child.lastPathComponent),
                    using: transfer
                )
            }
        } else {
            try await transfer.upload(source, to: target)
        }
    }

    private func uniqueRemoteDestination(named name: String, in directory: URL) async throws -> URL {
        var candidate = directory.appendingPathComponent(name)
        var index = 1
        while (try? await model.fileProvider.metadata(for: candidate)) != nil {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let nsName = name as NSString
            let base = nsName.deletingPathExtension
            let ext = nsName.pathExtension
            let newName = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            candidate = directory.appendingPathComponent(newName)
            index += 1
        }
        return candidate
    }

    @objc func revealInFinderAction() {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let urls = selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func openInTerminalAction() {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let directory = selectedItems.first(where: { $0.isBrowsableDirectory })?.url ?? model.directory
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = []
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: configuration)
    }

    /// Extracts the selected archive entries into a local folder.
    public func extractSelection(to destination: URL) {
        guard model.isArchive, let provider = archiveProvider else {
            NSSound.beep()
            return
        }
        let items = selectedItems
        guard !items.isEmpty else { return }

        let title = items.count == 1
            ? "Extract “\(items[0].name)”"
            : "Extract \(items.count) items"
        let activityID = ActivityLog.shared.begin(title: title, detail: destination.path)

        Task { [weak self] in
            guard let self else { return }
            var pairs: [FileOperationRecord.Pair] = []
            var failures: [String] = []
            for item in items {
                let target = FileTransfer.uniqueDestination(
                    for: destination.appendingPathComponent(item.name)
                )
                do {
                    try await provider.extract(provider.relativePath(for: item.url), to: target)
                    pairs.append(.init(source: item.url, target: target))
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
            if !pairs.isEmpty {
                self.onOperation?(FileOperationRecord(kind: .copy, pairs: pairs))
            }
            ActivityLog.shared.finish(
                activityID,
                status: failures.isEmpty ? .completed : .failed,
                message: failures.first
            )
            if let first = failures.first {
                self.presentMessage(
                    title: failures.count == 1 ? "An item could not be extracted" : "\(failures.count) items failed",
                    message: first
                )
            }
        }
    }

    /// Downloads the remote selection into a local folder (normally the other
    /// pane). Directories are walked with the same provider.
    public func downloadSelection(to destination: URL) {
        guard model.isRemote, let transfer = remoteTransfer else {
            NSSound.beep()
            return
        }
        let items = selectedItems
        guard !items.isEmpty else { return }

        let title = items.count == 1
            ? "Download “\(items[0].name)”"
            : "Download \(items.count) items"
        let activityID = ActivityLog.shared.begin(title: title, detail: destination.path)

        Task { [weak self] in
            guard let self else { return }
            var pairs: [FileOperationRecord.Pair] = []
            var failures: [String] = []

            for item in items {
                let target = FileTransfer.uniqueDestination(
                    for: destination.appendingPathComponent(item.name)
                )
                do {
                    try await self.downloadRemoteItem(item, to: target, using: transfer)
                    pairs.append(.init(source: item.url, target: target))
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }

            if !pairs.isEmpty {
                self.onOperation?(FileOperationRecord(kind: .copy, pairs: pairs))
            }
            ActivityLog.shared.finish(
                activityID,
                status: failures.isEmpty ? .completed : .failed,
                message: failures.first
            )
            if let first = failures.first {
                self.presentMessage(
                    title: failures.count == 1 ? "An item could not be downloaded" : "\(failures.count) items failed",
                    message: first
                )
            }
        }
    }

    private func downloadRemoteItem(
        _ item: FileItem,
        to target: URL,
        using transfer: RemoteFileTransferring
    ) async throws {
        if item.isDirectory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let children = try await model.fileProvider.list(
                item.url,
                options: ListOptions(showHidden: true)
            )
            for child in children {
                try await downloadRemoteItem(
                    child,
                    to: target.appendingPathComponent(child.name),
                    using: transfer
                )
            }
        } else {
            try await transfer.download(item.url, to: target)
        }
    }

    static func uniqueDestination(for url: URL) -> URL {
        FileTransfer.uniqueDestination(for: url)
    }

    // MARK: - Public command surface (used by MainWindowController)

    public func performNewFolder() { newFolderAction() }
    public func performRename() { renameAction() }
    public func performDuplicate() { duplicateAction() }
    public func performMoveToTrash() { moveToTrashAction() }
    public func performRevealInFinder() { revealInFinderAction() }
    public func performOpenInTerminal() { openInTerminalAction() }

    // MARK: - Transfers

    /// Copies or moves the current selection into `destination`.
    public func transferSelection(to destination: URL, kind: TransferKind) {
        let sources = selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        transfer(sources: sources, to: destination, kind: kind)
    }

    /// Copies or moves explicit URLs into `destination` (drag & drop, menu).
    public func transfer(
        sources: [URL],
        to destination: URL,
        kind: TransferKind,
        onFinish: ((TransferOutcome) -> Void)? = nil
    ) {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let destinationPath = destination.standardizedFileURL.path
        let inPlace = Set(
            sources
                .filter { $0.deletingLastPathComponent().standardizedFileURL.path == destinationPath }
                .map(\.path)
        )

        // Moving an item into its own folder is a no-op; copying one there is a
        // duplicate, so those sources never take part in the conflict dialog.
        var policies: [URL: TransferConflictPolicy] = [:]
        var pending = sources
        if kind == .move {
            pending = sources.filter { !inPlace.contains($0.path) }
        } else {
            for source in sources where inPlace.contains(source.path) {
                policies[source] = .keepBoth
            }
        }
        guard !pending.isEmpty else { return }

        let undecided = pending.filter { policies[$0] == nil }
        let conflicts = FileTransfer.conflicts(for: undecided, in: destination)
        guard let answers = resolveConflicts(conflicts, in: destination) else { return }
        for (url, policy) in answers {
            policies[url] = policy
        }

        let operationKind: FileOperationRecord.Kind = kind == .copy ? .copy : .move
        let activityTitle = FileOperationRecord(
            kind: operationKind,
            pairs: pending.map {
                .init(source: $0, target: destination.appendingPathComponent($0.lastPathComponent))
            }
        ).title
        let destinationName = destination.lastPathComponent
        let initialDetail = pending.count == 1
            ? "to “\(destinationName)”"
            : "\(pending.count) items to “\(destinationName)”"
        let activityID = ActivityLog.shared.begin(title: activityTitle, detail: initialDetail)

        let token = CancellationToken()
        activeTransferToken = token
        beginOperation(verb: kind == .copy ? "Copying" : "Moving", token: token)

        Task {
            let outcome = await FileTransfer().transfer(
                pending,
                to: destination,
                kind: kind,
                policy: .replace,
                policies: policies,
                isCancelled: { token.isCancelled },
                progress: { value in
                    Task { @MainActor [weak self] in
                        self?.showOperationProgress(value, token: token)
                        let current = value.currentName.isEmpty
                            ? initialDetail
                            : "“\(value.currentName)” → “\(destinationName)”"
                        ActivityLog.shared.update(activityID, detail: current, fraction: value.fraction)
                    }
                }
            )
            endOperation(token: token)
            if !outcome.cancelled, let failure = outcome.failures.first {
                presentMessage(
                    title: outcome.failures.count == 1
                        ? "An item could not be transferred"
                        : "\(outcome.failures.count) items could not be transferred",
                    message: "\(failure.url.lastPathComponent): \(failure.reason)"
                )
            }
            if !outcome.pairs.isEmpty {
                let pairs = outcome.pairs.map { FileOperationRecord.Pair(source: $0.source, target: $0.target) }
                onOperation?(FileOperationRecord(kind: operationKind, pairs: pairs))
            }

            let status: ActivityStatus = outcome.cancelled
                ? .cancelled
                : (outcome.failures.isEmpty ? .completed : .failed)
            let message = outcome.failures.first.map { "\($0.url.lastPathComponent): \($0.reason)" }
            let finalDetail = outcome.cancelled
                ? "Cancelled after \(outcome.pairs.count) of \(pending.count) items"
                : "\(outcome.pairs.count) of \(pending.count) items to “\(destinationName)”"
            ActivityLog.shared.update(activityID, detail: finalDetail)
            ActivityLog.shared.finish(activityID, status: status, message: message)

            model.reload()
            onFinish?(outcome)
        }
    }

    // MARK: - Operation progress

    private func beginOperation(verb: String, token: CancellationToken) {
        guard activeTransferToken === token else { return }
        operationVerb = verb
        operationProgressText = "\(verb)…"
        operationBar.doubleValue = 0
        operationBar.isHidden = false
        operationBarHeight?.constant = 6
        cancelButton.isHidden = false
        updateStatus()
    }

    private func showOperationProgress(_ value: TransferProgress, token: CancellationToken) {
        guard activeTransferToken === token else { return }
        operationBar.doubleValue = value.fraction * 100
        let percent = Int((value.fraction * 100).rounded())
        let name = value.currentName.isEmpty ? "" : " “\(value.currentName)”"
        operationProgressText = "\(operationVerb)\(name) — \(percent)%"
        updateStatus()
    }

    private func endOperation(token: CancellationToken) {
        guard activeTransferToken === token else { return }
        activeTransferToken = nil
        operationProgressText = nil
        operationBar.isHidden = true
        operationBarHeight?.constant = 0
        cancelButton.isHidden = true
        updateStatus()
    }

    @objc private func cancelTransfer(_ sender: Any?) {
        activeTransferToken?.cancel()
    }

    /// Escape closes the search bar first, otherwise cancels a running transfer.
    public override func cancelOperation(_ sender: Any?) {
        if searchVisible {
            endSearch()
            return
        }
        if let token = activeTransferToken {
            token.cancel()
            return
        }
        super.cancelOperation(sender)
    }

    /// Asks the user how to resolve existing destination names, one conflict at
    /// a time. Returns a per-item map, or `nil` when the user cancels.
    private func resolveConflicts(
        _ conflicts: [URL],
        in destination: URL
    ) -> [URL: TransferConflictPolicy]? {
        guard !conflicts.isEmpty else { return [:] }

        var answers: [URL: TransferConflictPolicy] = [:]
        for (index, source) in conflicts.enumerated() {
            let alert = NSAlert()
            alert.messageText = "An item named “\(source.lastPathComponent)” already exists in “\(destination.lastPathComponent)”."
            alert.informativeText = conflicts.count == 1
                ? "Choose how to handle the existing item."
                : "Conflict \(index + 1) of \(conflicts.count)."
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")

            if conflicts.count > 1 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Apply to all remaining conflicts"
            }

            let response = alert.runModal()
            let policy: TransferConflictPolicy
            switch response {
            case .alertFirstButtonReturn: policy = .keepBoth
            case .alertSecondButtonReturn: policy = .replace
            case .alertThirdButtonReturn: policy = .skip
            default: return nil
            }

            if alert.suppressionButton?.state == .on {
                for remaining in conflicts[index...] {
                    answers[remaining] = policy
                }
                return answers
            }
            answers[source] = policy
        }
        return answers
    }

    // MARK: - Clipboard

    @objc public func copy(_ sender: Any?) {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.write(urls, mode: .copy)
    }

    @objc public func cut(_ sender: Any?) {
        guard !model.isRemote, !model.isArchive else { NSSound.beep(); return }
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.write(urls, mode: .cut)
    }

    @objc public func paste(_ sender: Any?) {
        guard !model.isSearchResults, !model.isRemote, !model.isArchive else {
            NSSound.beep()
            return
        }
        let clipboard = FileClipboard.shared
        let destination = model.directory
        let kind: TransferKind = clipboard.isCut ? .move : .copy

        let urls = clipboard.urls
        // Cutting into the folder the items already live in is a no-op.
        let sources = kind == .move
            ? urls.filter { $0.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL }
            : urls
        guard !sources.isEmpty else { return }

        transfer(sources: sources, to: destination, kind: kind) { outcome in
            if kind == .move, !outcome.transferred.isEmpty {
                clipboard.consumeCut()
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Path bar with a context menu: right-clicking a component copies that
/// component's path, right-clicking empty space copies the current folder.
private final class PathBarControl: NSPathControl {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        var target = url
        if let cell = cell as? NSPathCell,
           let component = cell.pathComponentCell(at: point, withFrame: bounds, in: self),
           let componentURL = component.url {
            target = componentURL
        }
        guard let target else { return nil }

        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        menu.addItem(item)
        return menu
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }
}

/// Draws theme rows: background, alternating tint and a rounded selection
/// fill. Falls back to AppKit drawing when a theme leaves a color unspecified.
private final class ThemedRowView: NSTableRowView {
    var theme = Theme.system {
        didSet { needsDisplay = true }
    }
    var isAlternateRow = false {
        didSet { needsDisplay = true }
    }
    /// The inactive pane must not show a cursor at all.
    var showsSelection = true {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let background = theme.backgroundColor else {
            super.drawBackground(in: dirtyRect)
            return
        }
        let color = (isAlternateRow ? theme.alternateBackgroundColor : nil) ?? background
        color.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard showsSelection else { return }
        guard let selection = theme.selectionColor else {
            super.drawSelection(in: dirtyRect)
            return
        }
        selection.withAlphaComponent(isEmphasized ? 1 : 0.65).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
}

/// A table that makes its pane active on every click, including clicks on an
/// already selected row. Without this, clicking a row in a pane that is not
/// active leaves commands (copy, trash, paste) pointed at the other pane.
private final class ActivatingTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Space is Quick Look, as in Finder. Only without modifiers, so it
        // still reaches type-select when one is held.
        if event.keyCode == 49,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           let onQuickLook {
            onQuickLook()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Icon view

/// Collection view that reports activation, open-on-double-click and Space
/// the same way the table does.
private final class BrowserCollectionView: NSCollectionView {
    var onActivate: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           let onQuickLook {
            onQuickLook()
            return
        }
        super.keyDown(with: event)
    }
}

/// One file tile: icon above a two-line, centered name.
private final class IconItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 5
        badgeView.isHidden = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(nameLabel)
        container.addSubview(badgeView)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 60),
            iconView.heightAnchor.constraint(equalToConstant: 60),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),

            badgeView.widthAnchor.constraint(equalToConstant: 10),
            badgeView.heightAnchor.constraint(equalToConstant: 10),
            badgeView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -2),
            badgeView.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 2)
        ])
        view = container
    }

    func configure(name: String, image: NSImage, badgeColor: NSColor? = nil, badgeTip: String? = nil) {
        nameLabel.stringValue = name
        iconView.image = image
        badgeView.layer?.backgroundColor = badgeColor?.cgColor
        badgeView.isHidden = badgeColor == nil
        view.toolTip = badgeTip.map { "\(name) — \($0)" } ?? name
    }

    /// The inactive pane must not show a cursor at all.
    var hidesSelection = false {
        didSet { updateBackground() }
    }

    override var isSelected: Bool {
        didSet { updateBackground() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateBackground() }
    }

    private func updateBackground() {
        let selected = (isSelected || highlightState == .forSelection) && !hidesSelection
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor = selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }
}

/// Group header above an icon-view section.
private final class IconSectionHeader: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("IconSectionHeader")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String) {
        label.stringValue = title
    }
}

// MARK: - Icon view data source

extension BrowserPaneViewController: NSCollectionViewDataSource {
    public func numberOfSections(in collectionView: NSCollectionView) -> Int {
        iconSections.count
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard section < iconSections.count else { return 0 }
        return iconSections[section].items.count
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItemView.identifier, for: indexPath)
        guard let tile = item as? IconItemView,
              indexPath.section < iconSections.count,
              indexPath.item < iconSections[indexPath.section].items.count else {
            return item
        }
        let file = iconSections[indexPath.section].items[indexPath.item]
        tile.hidesSelection = !isActivePane
        let status = gitStatus(for: file)
        tile.configure(
            name: file.name,
            image: icon(for: file),
            badgeColor: status.map(gitBadgeColor(for:)),
            badgeTip: status?.summary
        )
        return tile
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: IconSectionHeader.identifier,
            for: indexPath
        )
        if let header = header as? IconSectionHeader, indexPath.section < iconSections.count {
            header.configure(title: iconSections[indexPath.section].title)
        }
        return header
    }
}

// MARK: - Icon view delegate

extension BrowserPaneViewController: NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isRestoringSelection else { return }
        selectedURLCache = Set(selectedItems.map(\.url))
        updateStatus()
        activate()
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !isRestoringSelection else { return }
        selectedURLCache = Set(selectedItems.map(\.url))
        updateStatus()
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> NSSize {
        model.settings.group == .none ? .zero : NSSize(width: 0, height: 26)
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard !model.isRemote, !model.isArchive else { return nil }
        guard indexPath.section < iconSections.count,
              indexPath.item < iconSections[indexPath.section].items.count else { return nil }
        return iconSections[indexPath.section].items[indexPath.item].url as NSURL
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard !model.isRemote, !model.isArchive else { return [] }
        return draggingInfo.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ? .copy : []
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let urls = draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty, !model.isRemote, !model.isArchive else {
            return false
        }
        let kind: TransferKind = draggingInfo.draggingSourceOperationMask.contains(.move)
            && NSEvent.modifierFlags.contains(.command) ? .move : .copy
        transfer(sources: urls, to: model.directory, kind: kind)
        return true
    }
}

// MARK: - Table data source & delegate

extension BrowserPaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ThemedRowView()
        rowView.theme = theme
        rowView.isAlternateRow = row % 2 == 1
        rowView.showsSelection = isActivePane
        return rowView
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let rows = self.rows
        guard row < rows.count else { return nil }

        switch rows[row] {
        case .group(let title):
            let identifier = NSUserInterfaceItemIdentifier("group")
            let cell = reusableCell(for: identifier, showsIcon: false)
            if column.identifier.rawValue == "name" {
                cell.textField?.stringValue = title.uppercased()
                cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                cell.textField?.textColor = .secondaryLabelColor
            } else {
                cell.textField?.stringValue = ""
            }
            return cell

        case .item(let item):
            let identifier = column.identifier
            let cell = reusableCell(for: identifier, showsIcon: identifier.rawValue == "name")
            guard let textField = cell.textField else { return cell }

            switch identifier.rawValue {
            case "name":
                let nameFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let nameColor: NSColor = item.isHidden ? .secondaryLabelColor : .labelColor
                textField.font = nameFont
                textField.textColor = nameColor
                cell.imageView?.image = icon(for: item)
                if let status = gitStatus(for: item), let badge = status.badgeLetter {
                    let text = NSMutableAttributedString(
                        string: item.name,
                        attributes: [.font: nameFont, .foregroundColor: nameColor]
                    )
                    text.append(NSAttributedString(
                        string: "  \(badge)",
                        attributes: [
                            .font: NSFont.monospacedSystemFont(
                                ofSize: NSFont.smallSystemFontSize,
                                weight: .bold
                            ),
                            .foregroundColor: gitBadgeColor(for: status)
                        ]
                    ))
                    textField.attributedStringValue = text
                    cell.toolTip = "\(item.name) — \(status.summary)"
                } else {
                    textField.stringValue = item.name
                    cell.toolTip = nil
                }
            case "path":
                textField.stringValue = item.url.path
                textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                textField.textColor = .secondaryLabelColor
            case "size":
                if !item.isDirectory {
                    textField.stringValue = Formatting.size(item.size)
                } else if let size = folderSizes[item.url] {
                    textField.stringValue = Formatting.size(size)
                } else if pendingFolderSizes.contains(item.url) {
                    textField.stringValue = "…"
                } else {
                    textField.stringValue = "--"
                }
            case "kind":
                textField.stringValue = item.kind
            case "modified":
                textField.stringValue = Formatting.modified(item.modified)
            default:
                textField.stringValue = ""
            }
            return cell
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        let rows = self.rows
        guard row < rows.count else { return false }
        if case .group = rows[row] { return false }
        return true
    }

    private func reusableCell(for identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.addSubview(textField)
        cell.textField = textField

        if showsIcon {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6)
            ])
        } else {
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4).isActive = true
        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // Restoring the cursor after a refresh must not steal the active pane.
        guard !isRestoringSelection else { return }
        selectedURLCache = Set(selectedItems.map(\.url))
        updateStatus()
        if tableView.selectedRowIndexes.isEmpty == false {
            activate()
        }
    }

    // MARK: - Drag & drop

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !model.isRemote, !model.isArchive else { return nil }
        let rows = self.rows
        guard row < rows.count, case .item(let item) = rows[row] else { return nil }
        return item.url as NSURL
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard !model.isSearchResults, !model.isRemote, !model.isArchive else { return [] }
        guard info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        // Dropping anywhere on the pane targets the pane's current folder.
        return .copy
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty, !model.isSearchResults, !model.isRemote, !model.isArchive else {
            return false
        }

        // Copy by default; holding Command turns the drop into a move.
        let kind: TransferKind = info.draggingSourceOperationMask.contains(.move)
            && NSEvent.modifierFlags.contains(.command) ? .move : .copy

        transfer(sources: urls, to: model.directory, kind: kind)
        return true
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        model.applySort(key, ascending: descriptor.ascending)
    }
}

// MARK: - Search field

extension BrowserPaneViewController: NSSearchFieldDelegate {
    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        // Escape closes the search bar even though the field editor would
        // otherwise just clear the text.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endSearch()
            return true
        }
        return false
    }
}

// MARK: - Context menu validation

extension BrowserPaneViewController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editSelectionAction) {
            return !model.isRemote
                && !model.isArchive
                && selectedItems.contains { !$0.isDirectory }
        }
        if menuItem.action == #selector(copyPathAction) {
            return !model.isArchive && !selectedItems.isEmpty
        }
        guard model.isRemote || model.isArchive else { return true }
        switch menuItem.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:)),
             #selector(duplicateAction), #selector(batchRenameAction),
             #selector(compressAction),
             #selector(revealInFinderAction), #selector(openInTerminalAction),
             #selector(openInOtherPane), #selector(chooseOpenWithApplication):
            return false
        default:
            return true
        }
    }
}

// MARK: - Open With submenu

extension BrowserPaneViewController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let url = focusedItem?.url else {
            let empty = menu.addItem(withTitle: "No Selection", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for application in OpenWithMenu.applications(for: url) {
            let entry = NSMenuItem(
                title: OpenWithMenu.displayName(for: application),
                action: #selector(openWithApplication(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = application
            entry.image = NSWorkspace.shared.icon(forFile: application.path)
            menu.addItem(entry)
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
}

public extension Notification.Name {
    static let openLiftOpenInOtherPane = Notification.Name("OpenLiftOpenInOtherPane")
    /// Requests the Get Info panel for the URLs in `userInfo["urls"]`.
    static let openLiftGetInfo = Notification.Name("openLiftGetInfo")
    /// Opens the advanced search window; `userInfo` carries the root folder,
    /// `recursive` and `focusContent`.
    static let openLiftAdvancedSearch = Notification.Name("openLiftAdvancedSearch")
    /// Opens a zip/tar archive in a read-only tab; `userInfo["url"]`.
    static let openLiftOpenArchive = Notification.Name("openLiftOpenArchive")
}

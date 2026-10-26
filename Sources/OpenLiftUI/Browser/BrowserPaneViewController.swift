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
    public var isActivePane = false

    /// Called when the pane becomes the active one (click, focus, navigation).
    public var onActivate: (() -> Void)?
    /// Called when the user opens a directory or file from this pane.
    public var onOpenDirectory: ((URL) -> Void)?

    private let pathControl = NSPathControl()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    private var iconCache: [String: NSImage] = [:]

    public init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.reloadView() }
        model.onError = { [weak self] error in self?.present(error: error) }
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
        configureTable()
        configureStatusBar()

        container.addSubview(pathControl)
        container.addSubview(scrollView)
        container.addSubview(statusLabel)
        container.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

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

    // MARK: - Configuration

    private func configurePathControl() {
        pathControl.url = model.directory
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.menu = makeContextMenu()
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.sortDescriptors = [NSSortDescriptor(key: model.settings.sort.key.rawValue, ascending: model.settings.sort.ascending)]

        addColumn(id: "name", title: "Name", width: 260)
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

    private func addColumn(id: String, title: String, width: CGFloat, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = 50
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
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
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelection), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Other Pane", action: #selector(openInOtherPane), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Folder", action: #selector(newFolderAction), keyEquivalent: "")
        menu.addItem(withTitle: "Rename…", action: #selector(renameAction), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrashAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinderAction), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Terminal", action: #selector(openInTerminalAction), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: - Rendering

    private func reloadView() {
        pathControl.url = model.directory
        let selected = Set(tableView.selectedRowIndexes)
        tableView.reloadData()
        let rows = IndexSet(selected.filter { $0 < model.displayItems.count })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        updateStatus()
        updateProgress()
        syncSortDescriptors()
    }

    private func updateProgress() {
        if model.isLoading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func updateStatus() {
        let count = model.displayItems.count
        let selected = tableView.selectedRowIndexes.count
        var text = count == 1 ? "1 item" : "\(count) items"
        if selected > 0 {
            text += ", \(selected) selected"
        }
        if let free = availableCapacity() {
            text += " — \(Formatting.size(free)) available"
        }
        statusLabel.stringValue = text
    }

    private func availableCapacity() -> Int64? {
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

    private func present(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t open folder"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Selection

    public var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { index in
            let items = model.displayItems
            return index < items.count ? items[index] : nil
        }
    }

    public var focusedItem: FileItem? {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : tableView.clickedRow
        let items = model.displayItems
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    public func activate() {
        isActivePane = true
        view.window?.makeFirstResponder(tableView)
        onActivate?()
    }

    public func deactivate() {
        isActivePane = false
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

    @objc public func openSelection() {
        guard let item = focusedItem else { return }
        if item.isBrowsableDirectory {
            model.navigate(to: item.url)
            onOpenDirectory?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc func openInOtherPane() {
        guard let item = focusedItem else { return }
        NotificationCenter.default.post(
            name: .openLiftOpenInOtherPane,
            object: self,
            userInfo: ["url": item.isBrowsableDirectory ? item.url : item.url.deletingLastPathComponent()]
        )
    }

    @objc func newFolderAction() {
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
        let provider = LocalFileProvider()
        Task {
            do {
                try await provider.createDirectory(at: destination)
                model.reload()
            } catch {
                present(error: error)
            }
        }
    }

    @objc func renameAction() {
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
        let provider = LocalFileProvider()
        Task {
            do {
                try await provider.move(item.url, to: destination)
                model.reload()
            } catch {
                present(error: error)
            }
        }
    }

    @objc func duplicateAction() {
        let provider = LocalFileProvider()
        let items = selectedItems
        Task {
            for item in items {
                let destination = Self.uniqueDestination(for: item.url)
                do {
                    try await provider.copy(item.url, to: destination)
                } catch {
                    present(error: error)
                }
            }
            model.reload()
        }
    }

    @objc func moveToTrashAction() {
        let provider = LocalFileProvider()
        let items = selectedItems
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                do {
                    try await provider.trash(item.url)
                } catch {
                    present(error: error)
                }
            }
            model.reload()
        }
    }

    @objc func revealInFinderAction() {
        let urls = selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func openInTerminalAction() {
        let directory = selectedItems.first(where: { $0.isBrowsableDirectory })?.url ?? model.directory
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = []
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: configuration)
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
    public func transfer(sources: [URL], to destination: URL, kind: TransferKind) {
        guard let policy = resolveConflictPolicy(for: sources, in: destination) else { return }

        Task {
            let outcome = await FileTransfer().transfer(
                sources,
                to: destination,
                kind: kind,
                policy: policy
            )
            if let failure = outcome.failures.first {
                presentMessage(
                    title: "Some items could not be transferred",
                    message: "\(failure.url.lastPathComponent): \(failure.reason)"
                )
            }
            model.reload()
        }
    }

    /// Asks the user how to resolve existing destination names.
    /// Returns `nil` when the user cancels.
    private func resolveConflictPolicy(for sources: [URL], in destination: URL) -> TransferConflictPolicy? {
        let conflicts = FileTransfer.conflicts(for: sources, in: destination)
        guard !conflicts.isEmpty else { return .replace }

        let alert = NSAlert()
        if conflicts.count == 1 {
            alert.messageText = "An item named “\(conflicts[0].lastPathComponent)” already exists in “\(destination.lastPathComponent)”."
        } else {
            alert.messageText = "\(conflicts.count) items already exist in “\(destination.lastPathComponent)”."
        }
        alert.informativeText = "Choose how to handle the existing items."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return nil
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

// MARK: - Table data source & delegate

extension BrowserPaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.displayItems.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let items = model.displayItems
        guard row < items.count else { return nil }
        let item = items[row]

        let identifier = column.identifier
        let cell = reusableCell(for: identifier, showsIcon: identifier.rawValue == "name")
        guard let textField = cell.textField else { return cell }

        switch identifier.rawValue {
        case "name":
            textField.stringValue = item.name
            cell.imageView?.image = icon(for: item)
            textField.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
        case "size":
            textField.stringValue = item.isDirectory ? "--" : Formatting.size(item.size)
        case "kind":
            textField.stringValue = item.kind
        case "modified":
            textField.stringValue = Formatting.modified(item.modified)
        default:
            textField.stringValue = ""
        }
        return cell
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
        updateStatus()
        if tableView.selectedRowIndexes.isEmpty == false {
            activate()
        }
    }

    // MARK: - Drag & drop

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let items = model.displayItems
        guard row < items.count else { return nil }
        return items[row].url as NSURL
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
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
        ) as? [URL], !urls.isEmpty else {
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

public extension Notification.Name {
    static let openLiftOpenInOtherPane = Notification.Name("OpenLiftOpenInOtherPane")
}

import AppKit
import OpenLiftCore
import UniformTypeIdentifiers

/// Advanced search: criteria on top, results and a content preview below.
///
/// Results can be sent to a regular OpenLift tab with “Show in Tab”, where the
/// normal list, Quick Look and context commands keep working.
@MainActor
public final class AdvancedSearchWindowController: NSWindowController {
    /// Called with all current results when the user asks for a tab.
    public var onShowInTab: (([FileItem]) -> Void)?
    /// Called when a folder result is opened; the caller usually opens a tab.
    public var onOpenFolder: ((URL) -> Void)?

    private let scopeLabel = NSTextField(labelWithString: "")
    private let nameField = NSSearchField()
    private let contentField = NSTextField()
    private let extensionField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let recursiveButton = NSButton(
        checkboxWithTitle: "Search subfolders",
        target: nil,
        action: nil
    )
    private let hiddenButton = NSButton(
        checkboxWithTitle: "Include hidden",
        target: nil,
        action: nil
    )
    private let previewButton = NSButton(
        checkboxWithTitle: "Preview",
        target: nil,
        action: nil
    )
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let showInTabButton = NSButton(title: "Show in Tab", target: nil, action: nil)
    private let quickLookButton = NSButton(title: "Quick Look", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let tableView = NSTableView()
    private let resultsScroll = NSScrollView()
    private let previewBox = NSView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewText = NSTextView()

    private var scope: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private var results: [FileItem] = []
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var cancellation: CancellationToken?
    private var isSearching = false

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Search"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        TestWindowPlacement.place(window)

        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and prepares a search in `scope`.
    public func present(scope: URL, recursive: Bool, focusContent: Bool = false) {
        cancelSearch()
        self.scope = scope.standardizedFileURL
        scopeLabel.stringValue = self.scope.path
        scopeLabel.toolTip = self.scope.path
        recursiveButton.state = recursive ? .on : .off
        results = []
        tableView.reloadData()
        clearPreview()
        statusLabel.stringValue = "Ready"
        setSearching(false)
        showWindow(nil)
        if TestWindowPlacement.isActive {
            window?.orderFront(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(focusContent ? contentField : nameField)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        scopeLabel.lineBreakMode = .byTruncatingMiddle
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chooseButton = NSButton(
            title: "Choose…",
            target: self,
            action: #selector(chooseScope(_:))
        )
        chooseButton.bezelStyle = .inline
        chooseButton.controlSize = .small

        let scopeRow = NSStackView(views: [scopeLabel, chooseButton])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8

        nameField.placeholderString = "Name contains (optional)"
        nameField.target = self
        nameField.action = #selector(startSearchAction(_:))
        nameField.sendsSearchStringImmediately = false
        nameField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        contentField.placeholderString = "Text inside files (optional)"
        contentField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        extensionField.placeholderString = "pdf, txt"
        extensionField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        typePopup.addItems(withTitles: SearchCriteria.ItemType.allCases.map(\.title))
        typePopup.selectItem(at: 0)
        typePopup.controlSize = .small

        recursiveButton.state = .on
        hiddenButton.state = .off

        let optionsRow = NSStackView(views: [
            extensionField,
            NSTextField(labelWithString: "Type:"),
            typePopup,
            recursiveButton,
            hiddenButton
        ])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 8

        let grid = NSGridView(views: [])
        grid.addRow(with: [label("Search in:"), scopeRow])
        grid.addRow(with: [label("Name contains:"), nameField])
        grid.addRow(with: [label("Text in contents:"), contentField])
        grid.addRow(with: [label("Extensions:"), optionsRow])
        grid.columnSpacing = 10
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        searchButton.target = self
        searchButton.action = #selector(startSearchAction(_:))
        searchButton.bezelStyle = .rounded
        searchButton.keyEquivalent = "\r"
        stopButton.target = self
        stopButton.action = #selector(stopSearch(_:))
        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true
        clearButton.target = self
        clearButton.action = #selector(clearResults(_:))
        clearButton.bezelStyle = .rounded
        previewButton.state = .off
        previewButton.target = self
        previewButton.action = #selector(togglePreview(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [
            searchButton,
            stopButton,
            clearButton,
            spacer,
            previewButton
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Results header.
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        quickLookButton.target = self
        quickLookButton.action = #selector(quickLookSelection(_:))
        quickLookButton.bezelStyle = .inline
        quickLookButton.controlSize = .small
        quickLookButton.isEnabled = false

        showInTabButton.target = self
        showInTabButton.action = #selector(showInTab(_:))
        showInTabButton.bezelStyle = .inline
        showInTabButton.controlSize = .small
        showInTabButton.isEnabled = false

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let resultsHeader = NSStackView(views: [
            statusLabel,
            progressIndicator,
            headerSpacer,
            quickLookButton,
            showInTabButton
        ])
        resultsHeader.orientation = .horizontal
        resultsHeader.spacing = 8
        resultsHeader.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        resultsScroll.documentView = tableView
        resultsScroll.hasVerticalScroller = true
        resultsScroll.hasHorizontalScroller = true
        resultsScroll.autohidesScrollers = true
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false

        configurePreview()
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.isHidden = true
        previewBox.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let resultsArea = NSStackView(views: [resultsScroll, previewBox])
        resultsArea.orientation = .horizontal
        resultsArea.spacing = 10
        resultsArea.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(buttons)
        content.addSubview(separator)
        content.addSubview(resultsHeader)
        content.addSubview(resultsArea)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            resultsHeader.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            resultsHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            resultsHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            resultsArea.topAnchor.constraint(equalTo: resultsHeader.bottomAnchor, constant: 6),
            resultsArea.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            resultsArea.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            resultsArea.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .inset
        tableView.target = self
        tableView.doubleAction = #selector(openResult(_:))

        addColumn("Name", width: 200)
        addColumn("Path", width: 380)
        addColumn("Size", width: 80, alignment: .right)
        addColumn("Kind", width: 120)
        addColumn("Modified", width: 140)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openResult(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Look", action: #selector(quickLookSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Get Info", action: #selector(getInfoSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Show in Tab", action: #selector(showInTab(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelection(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        tableView.menu = menu
    }

    private func addColumn(_ title: String, width: CGFloat, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        column.title = title
        column.width = width
        column.minWidth = 60
        column.headerCell.alignment = alignment
        tableView.addTableColumn(column)
    }

    private func configurePreview() {
        previewTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.lineBreakMode = .byTruncatingMiddle
        previewTitle.translatesAutoresizingMaskIntoConstraints = false

        let previewQuickLook = NSButton(
            title: "Quick Look",
            target: self,
            action: #selector(quickLookSelection(_:))
        )
        previewQuickLook.bezelStyle = .inline
        previewQuickLook.controlSize = .small
        previewQuickLook.setContentCompressionResistancePriority(.required, for: .horizontal)

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true

        let previewScroll = NSScrollView()
        previewScroll.documentView = previewText
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = false
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [previewTitle, previewQuickLook])
        header.orientation = .horizontal
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        previewBox.addSubview(header)
        previewBox.addSubview(previewScroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: previewBox.topAnchor),
            header.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),

            previewScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            previewScroll.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor)
        ])
    }

    // MARK: - Search lifecycle

    @objc private func chooseScope(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = scope
        panel.prompt = "Search Here"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.scope = url.standardizedFileURL
            self?.scopeLabel.stringValue = url.path
            self?.scopeLabel.toolTip = url.path
        }
    }

    @objc private func startSearchAction(_ sender: Any?) {
        startSearch()
    }

    private func startSearch() {
        cancelSearch()
        results = []
        tableView.reloadData()
        clearPreview()
        showInTabButton.isEnabled = false
        quickLookButton.isEnabled = false

        let type = SearchCriteria.ItemType.allCases[max(0, typePopup.indexOfSelectedItem)]
        let criteria = SearchCriteria(
            root: scope,
            nameContains: nameField.stringValue,
            contentContains: contentField.stringValue,
            recursive: recursiveButton.state == .on,
            includeHidden: hiddenButton.state == .on,
            itemType: type,
            extensions: extensionField.stringValue
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map(String.init)
        )

        let token = CancellationToken()
        cancellation = token
        setSearching(true)
        statusLabel.stringValue = "Searching…"

        searchTask = Task { [weak self] in
            for await event in SearchEngine().search(criteria, cancellation: token) {
                guard let self else { return }
                switch event {
                case .batch(let batch):
                    guard !batch.isEmpty else { continue }
                    self.appendResults(batch)
                case .progress(let progress):
                    self.statusLabel.stringValue = Self.progressText(progress)
                case .finished(let summary):
                    self.finishSearch(summary)
                }
            }
        }
    }

    private func appendResults(_ batch: [FileItem]) {
        let selectedURLs = Set(tableView.selectedRowIndexes.compactMap { row in
            row < results.count ? results[row].url : nil
        })
        results.append(contentsOf: batch)
        tableView.reloadData()

        // Keep a preview open while more batches arrive.
        if !selectedURLs.isEmpty {
            let rows = IndexSet(results.enumerated().compactMap { index, item in
                selectedURLs.contains(item.url) ? index : nil
            })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    private func finishSearch(_ summary: SearchSummary) {
        setSearching(false)
        cancellation = nil
        searchTask = nil

        var text = summary.matched == 1 ? "1 result" : "\(Self.number(summary.matched)) results"
        text += " · scanned \(Self.number(summary.scanned))"
        if summary.truncated { text += " · limit reached" }
        if summary.cancelled { text += " · stopped" }
        statusLabel.stringValue = text

        showInTabButton.isEnabled = !results.isEmpty
        if tableView.selectedRowIndexes.isEmpty, !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        quickLookButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    @objc private func stopSearch(_ sender: Any?) {
        cancellation?.cancel()
        statusLabel.stringValue = "Stopping…"
    }

    private func cancelSearch() {
        cancellation?.cancel()
        cancellation = nil
        searchTask?.cancel()
        searchTask = nil
        setSearching(false)
    }

    @objc private func clearResults(_ sender: Any?) {
        cancelSearch()
        results = []
        tableView.reloadData()
        clearPreview()
        statusLabel.stringValue = "Ready"
        showInTabButton.isEnabled = false
        quickLookButton.isEnabled = false
    }

    private func setSearching(_ searching: Bool) {
        isSearching = searching
        searchButton.isEnabled = !searching
        stopButton.isHidden = !searching
        stopButton.isEnabled = searching
        if searching {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private static func progressText(_ progress: SearchProgress) -> String {
        if progress.finished { return "Finishing…" }
        let base = "Scanning… \(number(progress.scanned)) items · \(number(progress.matched)) found"
        return progress.currentName.isEmpty ? base : "\(base) · \(progress.currentName)"
    }

    private static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    // MARK: - Results actions

    private var selectedResults: [FileItem] {
        tableView.selectedRowIndexes.compactMap { row in
            row < results.count ? results[row] : nil
        }
    }

    private var selectedResult: FileItem? { selectedResults.first }

    @objc private func openResult(_ sender: Any?) {
        guard let item = selectedResult else { return }
        if item.isBrowsableDirectory {
            onOpenFolder?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func quickLookSelection(_ sender: Any?) {
        let urls = selectedResults.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.present(urls)
    }

    @objc private func getInfoSelection(_ sender: Any?) {
        let urls = selectedResults.map(\.url)
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(
            name: .openLiftGetInfo,
            object: self,
            userInfo: ["urls": urls]
        )
    }

    @objc private func showInTab(_ sender: Any?) {
        guard !results.isEmpty else { return }
        onShowInTab?(results)
    }

    @objc private func revealSelection(_ sender: Any?) {
        let urls = selectedResults.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func togglePreview(_ sender: NSButton) {
        previewBox.isHidden = sender.state == .off
        if sender.state == .on {
            updatePreview()
        }
    }

    // MARK: - Preview

    private struct Preview {
        var text: String
        var note: String
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewTitle.stringValue = "No selection"
        previewTitle.toolTip = nil
        previewText.string = ""
    }

    private func updatePreview() {
        previewTask?.cancel()
        quickLookButton.isEnabled = !selectedResults.isEmpty

        guard let item = selectedResult, previewButton.state == .on else {
            clearPreview()
            return
        }

        previewTitle.stringValue = item.name
        previewTitle.toolTip = item.url.path

        if item.isDirectory {
            previewText.string = "Folder\n\n\(item.url.path)"
            return
        }

        previewText.string = "Loading…"
        let url = item.url
        previewTask = Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                Self.loadPreview(url)
            }.value
            guard let self, !Task.isCancelled, self.selectedResult?.url == url else { return }
            self.previewText.string = preview.text
            self.previewTitle.stringValue = "\(item.name) — \(preview.note)"
        }
    }

    nonisolated private static func loadPreview(_ url: URL) -> Preview {
        let limit = 256 << 10
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Preview(text: "Could not read this file.", note: "unreadable")
        }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        if data.isEmpty { return Preview(text: "", note: "0 bytes") }
        let truncated = data.count > limit
        let slice = truncated ? data.prefix(limit) : data

        if slice.prefix(4096).contains(0) {
            return Preview(text: "Binary file.\n\nUse Quick Look to preview it.", note: "binary")
        }

        let text = String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
        var note = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        if truncated { note += " preview" }
        return Preview(text: text, note: note)
    }
}

// MARK: - Table

extension AdvancedSearchWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count, let column = tableColumn else { return nil }
        let item = results[row]

        let text: String
        let color: NSColor
        let alignment: NSTextAlignment
        switch column.identifier.rawValue {
        case "Name":
            (text, color, alignment) = (item.name, .labelColor, .left)
        case "Path":
            (text, color, alignment) = (item.url.path, .secondaryLabelColor, .left)
        case "Size":
            (text, color, alignment) = (
                item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file),
                .secondaryLabelColor,
                .right
            )
        case "Kind":
            (text, color, alignment) = (item.kind, .secondaryLabelColor, .left)
        case "Modified":
            (text, color, alignment) = (
                item.modified.map { Self.dateFormatter.string(from: $0) } ?? "—",
                .secondaryLabelColor,
                .left
            )
        default:
            (text, color, alignment) = ("", .labelColor, .left)
        }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = item.url.path
        return field
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Window

extension AdvancedSearchWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        cancelSearch()
        previewTask?.cancel()
    }
}

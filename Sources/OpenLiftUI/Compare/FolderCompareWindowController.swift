import AppKit
import OpenLiftCore

/// Side-by-side folder comparison with one-click copies in either direction.
@MainActor
public final class FolderCompareWindowController: NSWindowController {
    public var onReload: (() -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyRightButton = NSButton(title: "Copy → Right", target: nil, action: nil)
    private let copyLeftButton = NSButton(title: "Copy ← Left", target: nil, action: nil)
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)

    private var leftRoot = URL(fileURLWithPath: "/")
    private var rightRoot = URL(fileURLWithPath: "/")
    private var result: FolderComparisonResult?
    private var isBusy = false

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare Folders"
        window.minSize = NSSize(width: 700, height: 380)
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

    public func present(left: URL, right: URL) {
        leftRoot = left
        rightRoot = right
        window?.title = "Compare “\(left.lastPathComponent)” ↔ “\(right.lastPathComponent)”"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        compare()
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .inset
        addColumn("Relative Path", width: 320)
        addColumn("Left", width: 180)
        addColumn("Right", width: 180)
        addColumn("Status", width: 130)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        copyRightButton.target = self
        copyRightButton.action = #selector(copyRight(_:))
        copyLeftButton.target = self
        copyLeftButton.action = #selector(copyLeft(_:))
        rescanButton.target = self
        rescanButton.action = #selector(rescan(_:))
        for button in [copyRightButton, copyLeftButton, rescanButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        copyRightButton.isEnabled = false
        copyLeftButton.isEnabled = false

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [
            summaryLabel,
            spinner,
            spacer,
            rescanButton,
            copyLeftButton,
            copyRightButton,
            closeButton
        ])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    private func addColumn(_ title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: .init(title))
        column.title = title
        column.width = width
        column.minWidth = 60
        tableView.addTableColumn(column)
    }

    // MARK: - Compare

    @objc private func rescan(_ sender: Any?) {
        compare()
    }

    private func compare() {
        guard !isBusy else { return }
        isBusy = true
        spinner.startAnimation(nil)
        summaryLabel.stringValue = "Comparing…"
        copyRightButton.isEnabled = false
        copyLeftButton.isEnabled = false
        let left = leftRoot
        let right = rightRoot

        Task { [weak self] in
            let outcome: Result<FolderComparisonResult, Error> = await Task.detached {
                do {
                    return .success(try FolderComparator().compare(left: left, right: right))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.isBusy = false
            self.spinner.stopAnimation(nil)

            switch outcome {
            case .success(let result):
                self.result = result
                self.tableView.reloadData()
                self.summaryLabel.stringValue =
                    "\(result.leftOnlyCount) only left · \(result.rightOnlyCount) only right · "
                    + "\(result.differentCount) different · \(result.sameCount) same"
                self.updateButtons()
            case .failure(let error):
                self.result = nil
                self.tableView.reloadData()
                self.summaryLabel.stringValue = "Comparison failed"
                let alert = NSAlert()
                alert.messageText = "Could not compare folders"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private var selectedEntries: [FolderDiffEntry] {
        guard let result else { return [] }
        return tableView.selectedRowIndexes.compactMap { row in
            row < result.entries.count ? result.entries[row] : nil
        }
    }

    private func updateButtons() {
        let selected = selectedEntries
        copyRightButton.isEnabled = !isBusy && selected.contains { $0.left != nil }
        copyLeftButton.isEnabled = !isBusy && selected.contains { $0.right != nil }
    }

    // MARK: - Sync

    @objc private func copyRight(_ sender: Any?) {
        copy(direction: .leftToRight)
    }

    @objc private func copyLeft(_ sender: Any?) {
        copy(direction: .rightToLeft)
    }

    private func copy(direction: FolderSync.Direction) {
        let entries = selectedEntries.filter {
            direction == .leftToRight ? $0.left != nil : $0.right != nil
        }
        guard !entries.isEmpty, !isBusy else { return }
        isBusy = true
        copyRightButton.isEnabled = false
        copyLeftButton.isEnabled = false
        spinner.startAnimation(nil)
        summaryLabel.stringValue = "Copying \(entries.count) items…"

        let left = leftRoot
        let right = rightRoot
        let title: String
        switch direction {
        case .leftToRight:
            title = entries.count == 1 ? "Copy to right" : "Copy \(entries.count) items to right"
        case .rightToLeft:
            title = entries.count == 1 ? "Copy to left" : "Copy \(entries.count) items to left"
        }
        let activityID = ActivityLog.shared.begin(title: title, detail: "")

        Task { [weak self] in
            let syncResult = await Task.detached {
                FolderSync().copy(
                    entries,
                    direction: direction,
                    leftRoot: left,
                    rightRoot: right
                )
            }.value
            guard let self else { return }
            self.isBusy = false
            self.spinner.stopAnimation(nil)
            ActivityLog.shared.finish(
                activityID,
                status: syncResult.failures.isEmpty ? .completed : .failed,
                message: syncResult.failures.first.map { "\($0.path): \($0.reason)" }
            )
            if let first = syncResult.failures.first {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = syncResult.failures.count == 1
                    ? "An item could not be copied"
                    : "\(syncResult.failures.count) items could not be copied"
                alert.informativeText = "\(first.path): \(first.reason)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            self.onReload?()
            self.compare()
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }
}

// MARK: - Table

extension FolderCompareWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        result?.entries.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let result, row < result.entries.count, let column = tableColumn else { return nil }
        let entry = result.entries[row]

        let text: String
        let color: NSColor
        switch column.identifier.rawValue {
        case "Relative Path":
            (text, color) = (entry.relativePath, .labelColor)
        case "Left":
            (text, color) = (describe(entry.left, root: leftRoot), .secondaryLabelColor)
        case "Right":
            (text, color) = (describe(entry.right, root: rightRoot), .secondaryLabelColor)
        case "Status":
            (text, color) = (entry.status.title, statusColor(entry.status))
        default:
            (text, color) = ("", .labelColor)
        }

        let field = NSTextField(labelWithString: text)
        field.font = column.identifier.rawValue == "Relative Path"
            ? .systemFont(ofSize: NSFont.smallSystemFontSize)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        return field
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private func describe(_ snapshot: FolderSnapshot?, root: URL) -> String {
        guard let snapshot else { return "—" }
        if snapshot.isDirectory { return "Folder" }
        var parts = [ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file)]
        if let modified = snapshot.modified {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            parts.append(formatter.string(from: modified))
        }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ status: FolderDiffStatus) -> NSColor {
        switch status {
        case .leftOnly, .rightOnly: return .systemBlue
        case .different: return .systemOrange
        }
    }
}

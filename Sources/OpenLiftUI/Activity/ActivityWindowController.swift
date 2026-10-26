import AppKit
import OpenLiftCore

/// A small window that shows running operations and the session history.
///
/// The window is a plain log viewer: each row is one transfer or instant file
/// operation, and running rows update in place with their percentage. It is
/// opened from Window ▸ Activity and kept for the lifetime of the main window,
/// so closing it merely hides it.
@MainActor
public final class ActivityWindowController: NSWindowController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No operations yet.")
    private let countLabel = NSTextField(labelWithString: "")
    private let log = ActivityLog.shared

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Activity"
        window.minSize = NSSize(width: 480, height: 220)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)

        configureContent()
        log.onChange = { [weak self] change in self?.apply(change) }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window, creating nothing if it is already open.
    public func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.style = .inset

        addColumn("Status", width: 95)
        addColumn("Operation", width: 190)
        addColumn("Details", width: 235)
        addColumn("Time", width: 62)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearLog(_:)))
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        content.addSubview(separator)
        content.addSubview(countLabel)
        content.addSubview(clearButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -5),

            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            countLabel.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            countLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor)
        ])
    }

    private func addColumn(_ title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: .init(title))
        column.title = title
        column.width = width
        column.minWidth = 50
        tableView.addTableColumn(column)
    }

    @objc private func clearLog(_ sender: Any?) {
        log.clear()
    }

    // MARK: - Rendering

    private func apply(_ change: ActivityChange) {
        switch change {
        case .inserted, .cleared:
            reload()
        case .updated(let id), .finished(let id):
            if let row = log.entries.firstIndex(where: { $0.id == id }) {
                tableView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<tableView.numberOfColumns))
            } else {
                reload()
            }
            updateFooter()
        }
    }

    private func reload() {
        tableView.reloadData()
        updateFooter()
        emptyLabel.isHidden = !log.entries.isEmpty
        emptyLabel.superview?.needsLayout = true
    }

    private func updateFooter() {
        let running = log.runningCount
        let total = log.entries.count
        if total == 0 {
            countLabel.stringValue = ""
        } else if running > 0 {
            countLabel.stringValue = "\(running) running · \(total) recorded"
        } else {
            countLabel.stringValue = total == 1 ? "1 operation" : "\(total) operations"
        }
    }

    private func label(_ text: String, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
}

// MARK: - Table data source & delegate

extension ActivityWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        log.entries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < log.entries.count else { return nil }
        let entry = log.entries[row]

        let text: String
        let color: NSColor
        switch column.identifier.rawValue {
        case "Status":
            (text, color) = statusText(for: entry)
        case "Operation":
            (text, color) = (entry.title, .labelColor)
        case "Details":
            if let message = entry.message {
                (text, color) = (message, .systemRed)
            } else {
                (text, color) = (entry.detail, .secondaryLabelColor)
            }
        case "Time":
            (text, color) = (Self.timeFormatter.string(from: entry.startedAt), .secondaryLabelColor)
        default:
            (text, color) = ("", .labelColor)
        }

        let cell = label(text, color: color)
        cell.toolTip = entry.message ?? entry.detail
        return cell
    }

    private func statusText(for entry: ActivityEntry) -> (String, NSColor) {
        switch entry.status {
        case .running:
            if let fraction = entry.fraction {
                return ("Running \(Int((fraction * 100).rounded()))%", .labelColor)
            }
            return ("Running…", .labelColor)
        case .completed:
            return ("Done", .secondaryLabelColor)
        case .cancelled:
            return ("Cancelled", .systemOrange)
        case .failed:
            return ("Failed", .systemRed)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

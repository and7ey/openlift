import AppKit
import OpenLiftCore

/// Batch rename sheet: a template with tokens, find/replace and numbering,
/// with a live old-name/new-name/status preview before applying.
@MainActor
public final class BatchRenameWindowController: NSWindowController {
    public var onApply: (([FileOperationRecord.Pair]) -> Void)?
    public var onDismiss: (() -> Void)?

    private let urls: [URL]
    private let planner = BatchRenamePlanner()
    private let templateField = NSTextField()
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let caseSensitiveButton = NSButton(
        checkboxWithTitle: "Case sensitive",
        target: nil,
        action: nil
    )
    private let startStepper = NSStepper()
    private let startLabel = NSTextField(labelWithString: "1")
    private let digitsStepper = NSStepper()
    private let digitsLabel = NSTextField(labelWithString: "1")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    private var plan: BatchRenamePlan
    private weak var parentWindow: NSWindow?

    public init(urls: [URL]) {
        self.urls = urls
        plan = BatchRenamePlan(entries: [])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Batch Rename"
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        TestWindowPlacement.place(window)
        super.init(window: window)
        window.delegate = self
        configureContent()
        refreshPlan()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func present(on parent: NSWindow?) {
        parentWindow = parent
        showWindow(nil)
        if let parent, let window {
            parent.beginSheet(window)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(templateField)
        templateField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        templateField.stringValue = "{name}{ext}"
        templateField.placeholderString = "{name}{ext}"
        templateField.toolTip = "Tokens: {name}, {ext}, {n}, {nn}, {nnn}, {date}"
        templateField.delegate = self
        templateField.widthAnchor.constraint(equalToConstant: 430).isActive = true

        findField.placeholderString = "Find in name"
        findField.delegate = self
        findField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        replaceField.placeholderString = "Replace with"
        replaceField.delegate = self
        replaceField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        caseSensitiveButton.target = self
        caseSensitiveButton.action = #selector(optionsChanged(_:))

        startStepper.minValue = 0
        startStepper.maxValue = 999_999
        startStepper.increment = 1
        startStepper.integerValue = 1
        startStepper.target = self
        startStepper.action = #selector(optionsChanged(_:))
        startLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        startLabel.alignment = .right
        startLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        digitsStepper.minValue = 1
        digitsStepper.maxValue = 8
        digitsStepper.increment = 1
        digitsStepper.integerValue = 1
        digitsStepper.target = self
        digitsStepper.action = #selector(optionsChanged(_:))
        digitsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        digitsLabel.alignment = .right
        digitsLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let findRow = NSStackView(views: [
            NSTextField(labelWithString: "Find:"),
            findField,
            NSTextField(labelWithString: "Replace:"),
            replaceField,
            caseSensitiveButton
        ])
        findRow.orientation = .horizontal
        findRow.spacing = 8

        let numberRow = NSStackView(views: [
            NSTextField(labelWithString: "Start at:"),
            startLabel,
            startStepper,
            NSTextField(labelWithString: "Minimum digits:"),
            digitsLabel,
            digitsStepper
        ])
        numberRow.orientation = .horizontal
        numberRow.spacing = 8

        let templateRow = NSStackView(views: [
            NSTextField(labelWithString: "Template:"),
            templateField
        ])
        templateRow.orientation = .horizontal
        templateRow.spacing = 8

        let hint = NSTextField(
            labelWithString: "Tokens: {name} (without extension), {ext} (with dot), "
                + "{n}/{nn}/{nnn} (number), {date}. Find/replace is applied to {name}."
        )
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let form = NSStackView(views: [templateRow, findRow, numberRow, hint])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [statusLabel, spacer, cancelButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(form)
        content.addSubview(scrollView)
        content.addSubview(buttonRow)
        form.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -10),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.allowsEmptySelection = true

        let oldColumn = NSTableColumn(identifier: .init("Old"))
        oldColumn.title = "Old Name"
        oldColumn.width = 230
        tableView.addTableColumn(oldColumn)

        let newColumn = NSTableColumn(identifier: .init("New"))
        newColumn.title = "New Name"
        newColumn.width = 230
        tableView.addTableColumn(newColumn)

        let statusColumn = NSTableColumn(identifier: .init("Status"))
        statusColumn.title = "Status"
        statusColumn.width = 220
        tableView.addTableColumn(statusColumn)
    }

    // MARK: - Plan

    @objc private func optionsChanged(_ sender: Any?) {
        refreshPlan()
    }

    private func refreshPlan() {
        startLabel.stringValue = "\(startStepper.integerValue)"
        digitsLabel.stringValue = "\(digitsStepper.integerValue)"

        let options = BatchRenameOptions(
            template: templateField.stringValue,
            find: findField.stringValue,
            replace: replaceField.stringValue,
            caseSensitive: caseSensitiveButton.state == .on,
            startNumber: startStepper.integerValue,
            numberPadding: digitsStepper.integerValue
        )
        plan = planner.plan(urls: urls, options: options)
        tableView.reloadData()

        let changes = plan.entries.filter(\.isChange).count
        if let firstIssue = plan.entries.first(where: { !$0.isValid })?.issue {
            statusLabel.stringValue = firstIssue
            statusLabel.textColor = .systemRed
        } else {
            let itemText = plan.entries.count == 1 ? "1 item" : "\(plan.entries.count) items"
            statusLabel.stringValue = "\(itemText) · \(changes) changes"
            statusLabel.textColor = .secondaryLabelColor
        }
        applyButton.isEnabled = plan.isValid && plan.hasChanges
    }

    // MARK: - Actions

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    @objc private func apply(_ sender: Any?) {
        guard plan.isValid, plan.hasChanges else { return }
        let plan = plan
        applyButton.isEnabled = false
        statusLabel.stringValue = "Renaming…"

        Task { [weak self] in
            do {
                let pairs = try await Task.detached(priority: .userInitiated) {
                    try BatchRenameExecutor().execute(plan)
                }.value
                guard let self else { return }
                self.onApply?(pairs)
                self.dismiss()
            } catch {
                guard let self else { return }
                self.applyButton.isEnabled = true
                self.refreshPlan()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Batch rename failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func dismiss() {
        if let parentWindow, let window, window.sheetParent != nil {
            parentWindow.endSheet(window)
        } else {
            window?.close()
        }
        onDismiss?()
    }
}

// MARK: - Table

extension BatchRenameWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        plan.entries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < plan.entries.count, let column = tableColumn else { return nil }
        let entry = plan.entries[row]

        let text: String
        let color: NSColor
        switch column.identifier.rawValue {
        case "Old":
            (text, color) = (entry.originalName, .labelColor)
        case "New":
            (text, color) = (entry.proposedName, entry.isValid ? .labelColor : .systemRed)
        case "Status":
            if let issue = entry.issue {
                (text, color) = (issue, .systemRed)
            } else if entry.isChange {
                (text, color) = ("Rename", .secondaryLabelColor)
            } else {
                (text, color) = ("No change", .tertiaryLabelColor)
            }
        default:
            (text, color) = ("", .labelColor)
        }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        return field
    }
}

// MARK: - Live editing

extension BatchRenameWindowController: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        refreshPlan()
    }
}

// MARK: - Window

extension BatchRenameWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        if let parentWindow, let window, window.sheetParent != nil {
            parentWindow.endSheet(window)
        }
        onDismiss?()
    }
}

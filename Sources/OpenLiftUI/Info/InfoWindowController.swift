import AppKit
import OpenLiftCore
import UniformTypeIdentifiers

/// A compact Get Info panel for the current selection (⌘I).
///
/// One window is reused per browser window: asking for info on another
/// selection updates the same panel instead of stacking windows.
@MainActor
public final class InfoWindowController: NSWindowController {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")
    private let grid = NSGridView(views: [])

    private let labels = ["Kind", "Size", "Where", "Created", "Modified", "Permissions", "Owner"]
    private var valueFields: [NSTextField] = []

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Info"
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

    public func showInfo(for urls: [URL]) {
        guard let first = urls.first else { return }
        update(urls, first: first)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.translatesAutoresizingMaskIntoConstraints = false

        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.translatesAutoresizingMaskIntoConstraints = false

        let headerText = NSStackView(views: [nameField, pathField])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        headerText.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [iconView, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        for _ in labels {
            let field = NSTextField(labelWithString: "—")
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            valueFields.append(field)
        }

        for (index, label) in labels.enumerated() {
            let name = NSTextField(labelWithString: label)
            name.textColor = .secondaryLabelColor
            name.alignment = .right
            grid.addRow(with: [name, valueFields[index]])
        }
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(grid)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)
        ])
    }

    // MARK: - Content

    private func update(_ urls: [URL], first: URL) {
        let single = urls.count == 1
        window?.title = single ? "\(first.lastPathComponent) Info" : "\(urls.count) Items Info"

        iconView.image = single
            ? NSWorkspace.shared.icon(forFile: first.path)
            : NSImage(named: NSImage.multipleDocumentsName)
        nameField.stringValue = single ? first.lastPathComponent : "\(urls.count) items"
        pathField.stringValue = single ? first.path : commonParent(of: urls) ?? "Multiple locations"

        let details = describe(urls, first: first)
        for (field, value) in zip(valueFields, details) {
            field.stringValue = value
        }
    }

    private func describe(_ urls: [URL], first: URL) -> [String] {
        let single = urls.count == 1
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)

        let kind: String
        if single {
            let type = (try? first.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            kind = type?.localizedDescription ?? (isDirectory.boolValue ? "Folder" : "Document")
        } else {
            kind = "\(urls.count) items"
        }

        let size: String
        if single {
            size = isDirectory.boolValue ? "—" : Self.byteCount(of: first)
        } else {
            let total = urls.reduce(Int64(0)) { sum, url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDir ? sum : sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0)
            }
            size = total > 0
                ? "\(Self.byteCount(total)) — \(urls.count) items"
                : "\(urls.count) items"
        }

        let where_ = single ? first.deletingLastPathComponent().path : (commonParent(of: urls) ?? "Multiple locations")
        let created = single ? Self.dateString(for: first, key: .creationDateKey) : "—"
        let modified = single ? Self.dateString(for: first, key: .contentModificationDateKey) : "—"

        var permissions = "—"
        var owner = "—"
        var info = stat()
        if single, first.path.withCString({ stat($0, &info) }) == 0 {
            permissions = "\(Self.modeString(info.st_mode)) (\(String(info.st_mode & 0o777, radix: 8)))"
            if let passwd = getpwuid(info.st_uid) {
                owner = String(cString: passwd.pointee.pw_name)
            }
        }

        return [kind, size, where_, created, modified, permissions, owner]
    }

    private func commonParent(of urls: [URL]) -> String? {
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        return parents.count == 1 ? parents.first : nil
    }

    // MARK: - Formatting

    private static func byteCount(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return byteCount(Int64(size))
    }

    private static func byteCount(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static func dateString(for url: URL, key: URLResourceKey) -> String {
        guard let values = try? url.resourceValues(forKeys: [key]) else { return "—" }
        let date = key == .creationDateKey ? values.creationDate : values.contentModificationDate
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    /// `drwxr-xr-x`-style mode summary.
    private static func modeString(_ mode: mode_t) -> String {
        let type: Character
        switch mode & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        default: type = "-"
        }
        let bits: [(mode_t, Character)] = [
            (S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
            (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
            (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")
        ]
        return String(type) + String(bits.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

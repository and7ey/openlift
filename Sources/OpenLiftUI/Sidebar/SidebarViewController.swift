import AppKit
import OpenLiftCore

/// Sidebar showing favorites, groups and locations.
@MainActor
public final class SidebarViewController: NSViewController {
    /// Called when the user picks a location.
    public var onSelect: ((URL) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let store: FavoritesStore
    private var roots: [FavoriteNode] = []

    public init(store: FavoritesStore = FavoritesStore()) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 12
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.floatsGroupRows = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container

        reloadFavorites()
    }

    public func reloadFavorites() {
        // `.smart` groups are generated from the live system on every load.
        var favorites = store.load().filter { $0.kind != .smart }
        favorites.append(Self.dynamicLocations())
        roots = favorites.map(FavoriteNode.init)
        outlineView.reloadData()
        roots.forEach { outlineView.expandItem($0) }
    }

    /// Builds the Locations section from mounted volumes.
    private static func dynamicLocations() -> Favorite {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var children: [Favorite] = []
        for url in volumes {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable ?? true else { continue }

            let isRoot = url.path == "/"
            let name = isRoot ? "Macintosh HD" : (values?.volumeName ?? url.lastPathComponent)
            let isLocal = values?.volumeIsLocal ?? true
            let symbol = isRoot ? "internaldrive" : (isLocal ? "externaldrive" : "externaldrive.connected.to.line.below")
            children.append(Favorite(kind: .path, name: name, path: url.path, symbol: symbol))
        }

        children.sort { lhs, rhs in
            if lhs.path == "/" { return true }
            if rhs.path == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return Favorite(kind: .smart, name: "Locations", symbol: "externaldrive", children: children)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        reloadFavorites()
    }
}

// MARK: - Node wrapper

@MainActor
final class FavoriteNode: NSObject {
    let favorite: Favorite
    let children: [FavoriteNode]

    init(_ favorite: Favorite) {
        self.favorite = favorite
        self.children = (favorite.children ?? []).map(FavoriteNode.init)
        super.init()
    }

    var isGroup: Bool { favorite.kind == .group }
    var url: URL? { favorite.url }
}

// MARK: - Outline data source & delegate

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FavoriteNode else { return roots.count }
        return node.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FavoriteNode else { return roots[index] }
        return node.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FavoriteNode)?.children.isEmpty == false
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FavoriteNode)?.isGroup ?? false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FavoriteNode else { return false }
        return !node.isGroup
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FavoriteNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier(node.isGroup ? "group" : "row")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = node.isGroup
                ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                : .systemFont(ofSize: NSFont.systemFontSize)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = node.favorite.name
        cell.textField?.textColor = node.isGroup ? .secondaryLabelColor : .labelColor
        cell.imageView?.image = node.favorite.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FavoriteNode, let url = node.url else { return }
        onSelect?(url)
    }
}

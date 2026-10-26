# MVP specification — local dual-pane file manager

This is the specification OpenLift's local MVP is built against. It is an
original design informed by observing how mature dual-pane managers behave; no
code or assets are reused.

## 1. Goal

Replace Finder for everyday local file work:

- two panes, tabs, sidebar, path bar, status bar;
- file list with sorting, grouping and hidden files;
- copy / move / trash / rename / new / duplicate, drag & drop, queue and
  conflict handling;
- undo, Quick Look, Get Info, Open With, search in the current folder;
- window, tab and favorites state survives a restart.

Out of scope for the MVP: remote protocols (SFTP/FTP/WebDAV), cloud drives,
sync, git, archive browsing (ZIP creation only), batch rename, custom themes,
App Deleter, AppleScript, auto-update, iCloud favorites sync, column view.

## 2. Package layout

```
Sources/
  OpenLiftCore/
    Browser/BrowserModel.swift
    Model/{FileItem,SortDescriptor,ViewSettings,Favorite,FileItemOrdering}.swift
    Provider/{FileProvider,LocalFileProvider,DirectoryWatcher}.swift
    Persistence/{FavoritesStore,WindowStateStore}.swift
  OpenLiftUI/
    Browser/BrowserPaneViewController.swift
    Sidebar/SidebarViewController.swift
    Formatting.swift
  OpenLiftApp/
    AppDelegate.swift
    MainWindowController.swift
    MenuBuilder.swift
  OpenLift/main.swift
```

## 3. Key types

### FileProvider

Introduced immediately so remote sources do not reshape the UI later.

```swift
protocol FileProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    func list(_ directory: URL, options: ListOptions) async throws -> [FileItem]
    func metadata(for url: URL) async throws -> FileItem
    func createDirectory(at url: URL) async throws
    func move(_ source: URL, to destination: URL) async throws
    func copy(_ source: URL, to destination: URL) async throws
    func delete(_ url: URL) async throws
    func trash(_ url: URL) async throws -> URL
    func isDirectory(_ url: URL) async -> Bool
}
```

`LocalFileProvider` is the only implementation in the MVP.

### FileItem

Immutable snapshot: `url`, `name`, `isDirectory`, `isSymlink`, `isHidden`,
`isPackage`, `isAlias`, `size`, `modified`, `created`, `contentTypeIdentifier`,
`permissions`, `owner`.

### BrowserModel

Per-pane state: current directory, listing, history stacks, view settings,
async load lifecycle and an FSEvents watcher. Views observe `onChange`; the
model also posts `openLiftBrowserModelDidChange` for window-level observers.

### Commands

All actions live in one command surface (`MainWindowController`), invoked by
menu items, toolbar buttons and keyboard shortcuts.

### Operations (M2)

```swift
struct FileOperation: Sendable {
    enum Kind: Sendable { case copy, move, trash, delete, rename, duplicate, compress }
    let kind: Kind
    let sources: [URL]
    let destination: URL?
    let conflictPolicy: ConflictPolicy
}

enum OperationEvent: Sendable {
    case started(total: Int)
    case progress(completed: Int, total: Int, current: URL)
    case conflict(ConflictRequest)
    case finished(OperationResult)
    case failed(OperationError)
}

actor OperationQueue {
    func enqueue(_ operation: FileOperation) -> AsyncStream<OperationEvent>
    func cancel(id: UUID)
}
```

Undo stores inverse operations; trash → restore from the URL returned by
`FileManager.trashItem`. Cancelling a copy removes partial files; cross-volume
moves copy to a temporary name and rename on success.

### Conflicts

Policies: `replace`, `skip`, `keepBoth`, `mergeFolders`, `ask`. The dialog
shows source/destination, size and dates, with "apply to all".

## 4. UI

- `NSSplitViewController`: sidebar + two panes.
- Each pane: path bar, list/icon mode, tab bar, status bar.
- List mode: `NSTableView` with `name`, `size`, `kind`, `modified` columns in
  the MVP; the column registry is extensible.
- Icon mode: `NSCollectionView` (after the core MVP).
- Preview: `QLPreviewPanel` plus a metadata inspector.
- Activities: a separate window listing operations, progress and logs.
- Menus and shortcuts follow the command map, validated by hand.

## 5. Persistence

- Favorites: `Codable` tree in
  `~/Library/Application Support/OpenLift/favorites.json`.
- Window state: frame, pane paths, history, settings in `window-state.json`.
- Settings: `UserDefaults` (`showHidden`, `foldersFirst`, `confirmDelete`,
  `defaultViewMode`).
- No secrets in the MVP.

## 6. Milestones

| Milestone | Output |
|---|---|
| M0. Scaffold | SPM package, app + core, window with two panes, menu |
| M1. Browser | listing, metadata, sorting, navigation, tabs, sidebar, volumes, FSEvents |
| M2. Operations | copy/move/trash/rename/new/duplicate, drag & drop, queue, conflicts, undo |
| M3. Comfort | Quick Look, Get Info, search, zip, settings, persistence, polish |
| M4. Stabilization | tests, 100k-file performance, error handling, release build |

## 7. Acceptance criteria

1. Two panes, tabs and favorites survive a restart.
2. Every core command is reachable from menu, toolbar and keyboard.
3. Copying a 10 GB folder shows progress, cancels without leftovers, and
   applies the chosen conflict policy.
4. Drag & drop works between panes, from Finder, and to Finder.
5. Rename/trash/undo never lose data.
6. A 100 000-file directory opens in under a second and scrolls smoothly.
7. Permission errors (Full Disk Access) are explained in a dialog.
8. The UI never blocks during long operations.

## 8. Tests

- Unit: sorting, grouping, path math, conflict policy, undo stack.
- Integration: temporary directories; copy matrix (file/folder/symlink/xattr/
  permissions/cross-volume); trash and put back; cancellation.
- Performance: 100k-file generator; measure open, scroll, search.
- UI smoke: launch, two panes, menus, Quick Look.

## 9. Risks

| Risk | Mitigation |
|---|---|
| `NSTableView` performance | view reuse, async metadata, measure at 100k |
| Data loss in copy/undo | atomic temporary names, integration matrix |
| Conflicts in bulk operations | dedicated resolver, "apply to all", logging |
| FSEvents storms | debounce, refresh only affected paths |
| Non-sandboxed distribution | Developer ID + notarization later; ad-hoc locally |

# OpenLift

An open-source, native macOS dual-pane file manager and file-transfer client,
built from scratch in Swift and AppKit.

OpenLift is an independent implementation. It is inspired by the workflow of
commercial dual-pane managers (ForkLift in particular), but contains no code,
assets, icons, localizations or other material from them. See
[Legal](#legal).

## Status

Early development. The local-file MVP is in progress:

| Area | State |
|---|---|
| App scaffold, SPM build, `.app` bundling | done |
| Two panes, sidebar, path bar, status bar, toolbar | done |
| List view, sortable columns, folders-first | done |
| Navigation (double-click, back/forward/up/home, path bar, sidebar) | done |
| Show hidden files | done |
| New folder, rename, duplicate, trash, reveal, open in Terminal | done |
| Live refresh via FSEvents | done |
| Window/favorites persistence | done |
| Tabs per pane, mounted volumes, grouping, per-folder settings | done |
| Drag & drop, copy/move between panes | done |
| Clipboard (cut/copy/paste, Finder interop) | done |
| Transfers: progress, cancel, conflicts with “apply to all” | done |
| Undo / redo (copy/move/rename/trash/new folder) | done |
| Activity window (live progress, session log) | done |
| Quick Look, Get Info, Open With | done |
| Search in folder, ZIP archives | done |
| Icon view | done |
| Settings window | done |
| Keyboard shortcut customization | done |
| Remote providers (SFTP, FTP, WebDAV, S3, cloud) | planned (post-MVP) |

## Requirements

- macOS 14 or newer
- Swift 6.3 toolchain

A full Xcode installation is **not** required: the app builds with the Command
Line Tools and `swift build`. XCTest-based tests do require Xcode; until then,
use the dependency-free self-test runner.

## Build and run

```sh
# Build + assemble build/OpenLift.app (ad-hoc signed)
./Scripts/make-app.sh debug
open build/OpenLift.app

# Or run the binary directly
swift run OpenLift
```

Release build:

```sh
./Scripts/make-app.sh release
```

## Tests

```sh
swift run OpenLiftSelfTest
```

The runner covers ordering/grouping, favorites persistence, per-folder view
settings, tab-aware window state, the local provider (listing, hidden files,
move, create, delete), file transfers and the FSEvents watcher. When Xcode is
available, `Tests/OpenLiftTests/OpenLiftTests.swift` can be re-enabled as a
`swift-testing` target in `Package.swift`.

## Architecture

```
Sources/
  OpenLiftCore/       platform-independent model, providers, persistence
    Browser/          BrowserModel — listing, history, sorting, grouping, FSEvents
    Model/            FileItem, SortDescriptor, ViewSettings, Favorite
    Operations/       TransferPlanner, TransferExecutor, progress, cancellation
    Provider/         FileProvider protocol, LocalFileProvider, DirectoryWatcher
    Persistence/      FavoritesStore, WindowStateStore, ViewSettingsStore
  OpenLiftUI/         AppKit views
    Browser/          BrowserTabsViewController, BrowserPaneViewController,
                      PaneTabBarView (path bar, table, status bar)
    Clipboard/        FileClipboard — file URLs + cut marker on NSPasteboard
    Activity/         ActivityWindowController — live progress + session log
    Info/             InfoWindowController — Get Info panel
    Preview/          QuickLookController, OpenWithMenu
    Sidebar/          SidebarViewController (favorites + mounted volumes)
  OpenLiftApp/        application shell
    MainWindowController  window, split view, command routing, toolbar
    MenuBuilder           menu bar
    AppDelegate           lifecycle
  OpenLift/           executable entry point
```

Design notes:

- `FileProvider` exists from day one, even though only `LocalFileProvider` is
  shipped, so remote sources will not force a rewrite of the browser.
- `BrowserModel` is the single source of truth for a pane; views observe it.
- Commands flow through one command surface (`MainWindowController` selectors)
  shared by menu, toolbar and keyboard.
- Transfers are planned before they start (targets, conflicts, total bytes),
  then written under a hidden staging name and renamed into place, so a
  cancelled or failed operation never leaves a partial file; metadata is
  copied with `copyfile(3)`.
- Settings apply view options to every open folder (hidden files, folders
  first), keep the recent-operations limit (undo + activity) in `UserDefaults`,
  clear the activity log, and can reset every folder's view settings.
- Shortcuts are overrides on top of `ShortcutCommand` defaults: the recorder
  refuses conflicts with any menu item, cleared shortcuts stay cleared, and
  the menu is re-keyed immediately and at launch.
- The icon view is the same pane model in an `NSCollectionView`: selection,
  search, grouping, drag & drop, Quick Look and every command work the same,
  and list/icon mode is remembered per folder.
- Search is a live, case-insensitive name filter on the current folder
  (`BrowserModel.searchQuery`); it does not walk into subfolders.
- “Compress” builds a ZIP with the system `zip` tool, so there is no archive
  dependency; the work runs off the main actor and is logged in Activity.
- `ActivityLog` is an in-memory session log shared by the panes and the
  Activity window (Window ▸ Activity). Running transfers update one entry in
  place, so the log doubles as a progress view and as the operation history.
- Undo/redo uses two stacks of `FileOperationRecord` rather than `UndoManager`,
  because reversing a transfer is asynchronous. Each record stores both URLs,
  so undo never guesses names; undoing a copy moves the copy to the Trash (an
  item it replaced is not restored), undoing a move/rename moves it back, and
  undoing a new folder trashes it.
- Persistence is plain `Codable` JSON under
  `~/Library/Application Support/OpenLift/`.

See [`docs/spec/mvp.md`](docs/spec/mvp.md) for the full MVP specification and
[`docs/roadmap.md`](docs/roadmap.md) for milestones.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New Tab | ⌘T |
| Close Tab | ⌘W |
| Next / Previous Tab | ⌃⇥ / ⌃⇧⇥ |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| New Folder | ⇧⌘N |
| Rename | ↩ |
| Duplicate | ⌘D |
| Open | ⌘O |
| Move to Trash | ⌘⌫ |
| Reveal in Finder | ⇧⌘R |
| Open in Terminal | ⌃⌘T |
| Back / Forward | ⌘[ / ⌘] |
| Enclosing Folder | ⌘↑ |
| Home | ⇧⌘H |
| Refresh | ⌘R |
| Cancel a running transfer | Esc |
| Activity window | ⌥⌘A |
| Quick Look | Space or ⌘Y |
| Get Info | ⌘I |
| Find in folder | ⌘F |
| Settings | ⌘, |
| Show Hidden Files | ⇧⌘. |
| Show Sidebar | ⌃⌘S |
| Single Pane | ⌘\ |
| Swap Panes | ⇧⌘S |

## Legal

OpenLift is an independent, clean-room implementation. It contains no
decompiled code, resources, icons, localizations or branding from any
commercial product. Reverse-engineering research, when performed, is used only
to understand observable behaviour and to inform an original design.

## License

MIT — see [`LICENSE`](LICENSE).

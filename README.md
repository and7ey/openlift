# OpenLift

An open-source, native macOS dual-pane file manager and file-transfer client,
built from scratch in Swift and AppKit.

OpenLift is a public, open-source analog of the commercial macOS file manager
ForkLift. It is an independent implementation inspired by the same dual-pane
workflow, but contains no code, assets, icons, localizations or other material
from it. See [Legal](#legal).

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
| Batch rename (template, find/replace, numbering, live preview) | done |
| Undo / redo (copy/move/rename/trash/new folder) | done |
| Activity window (live progress, session log) | done |
| Quick Look, Get Info, Open With | done |
| Remote: SFTP/FTP/WebDAV browsing, transfers, mutations, bookmarks | done (FTPS live check pending) |
| Cloud Drives: iCloud, Dropbox, Google Drive, OneDrive, Box folders | done via desktop clients |
| Folder compare and copy sync | done (copy-only) |
| Archive browsing (zip/tar, extract) | done |
| Git: status badges, branch/ahead-behind, stage/unstage, discard, commit | done |
| Search: in-folder filter + advanced window (recursive, content, preview) | done |
| ZIP archives | done |
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

The app icon lives in `Resources/OpenLift.icns`. Regenerate it after editing
the vector-like drawing in `Scripts/make-icon.swift`:

```sh
./Scripts/make-icon.sh
```

## Tests

```sh
swift run OpenLiftSelfTest
```

For UI runs that must not steal focus from the person at the Mac, debug builds
accept `OPENLIFT_TESTING=1`: OpenLift starts as an accessory app, places its
windows on a screen whose name contains “OpenLift Test Display”, and a local
`dev.openlift.test` distributed-notification channel drives whitelisted commands.
Release builds compile the bridge out.

The runner covers ordering/grouping, favorites persistence, per-folder view
settings, tab-aware window state, the local provider (listing, hidden files,
move, create, delete), file transfers, undo records, the activity log, search,
archives, advanced search, batch rename, archive browsing, Git status/actions, cloud drives, folder compare/sync, remote listings/bookmarks, WebDAV listings, app settings and shortcuts — 225 checks, all
dependency-free. When Xcode is
available, `Tests/OpenLiftTests/OpenLiftTests.swift` can be re-enabled as a
`swift-testing` target in `Package.swift`.

## Performance

```sh
# Reuses /tmp/openlift-bench-<count> after the first run.
Scripts/benchmark.sh 100000
```

On the development machine (release build, APFS, warm cache), a 100k-item
folder lists in about 1.5 s and sorts in about 0.5 s. The browser caches the
sorted/filtered/grouped view per change, so scrolling and selection do not
re-sort the folder; AppKit only materializes visible rows. A 100k-folder
session sits around 320 MB resident.

## Architecture

```
Sources/
  OpenLiftCore/       platform-independent model, providers, persistence
    Browser/          BrowserModel — listing, history, sorting, grouping, FSEvents
    Model/            FileItem, SortDescriptor, ViewSettings, Favorite
    Persistence/      FavoritesStore, WindowStateStore, ViewSettingsStore,
                      CloudDriveLocator
    Operations/       TransferPlanner, TransferExecutor, SearchEngine,
                      FolderComparator, FolderSync, progress
    Git/              GitClient — porcelain status parser and stage/commit actions
    Provider/         FileProvider protocol, LocalFileProvider, SearchResultsProvider,
                      SFTPRemoteProvider, FTPRemoteProvider, WebDAVRemoteProvider,
                      ArchiveFileProvider, RemoteBookmark, DirectoryWatcher
  OpenLiftUI/         AppKit views
    Browser/          BrowserTabsViewController, BrowserPaneViewController,
                      PaneTabBarView (path bar, table, status bar)
    Clipboard/        FileClipboard — file URLs + cut marker on NSPasteboard
    Activity/         ActivityWindowController — live progress + session log
    Search/           AdvancedSearchWindowController — criteria, results, preview
    Remote/           RemoteConnectionWindowController — SFTP/FTP/WebDAV sheet
    Info/             InfoWindowController — Get Info panel
    Preview/          QuickLookController, OpenWithMenu
    Compare/          FolderCompareWindowController — diff table + copy sync
    Sidebar/          SidebarViewController (favorites, volumes, cloud drives)
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
- Quick search is a live, case-insensitive name filter on the current folder
  (`BrowserModel.searchQuery`); it does not walk into subfolders.
- Advanced search runs `SearchEngine` off the main actor and streams batches.
  It supports recursion, hidden files, files/folders/extension filters and
  text-in-file matching (UTF-8/Latin-1, binary files and files over 16 MB are
  skipped). The magnifier next to the path bar offers filter, folder,
  recursive and content searches.
- “Show in Tab” opens results as a virtual `SearchResultsProvider` tab:
  full paths, Quick Look, Get Info and item-level commands (trash, rename,
  compress) work, while paste, new folder and navigation into the virtual
  folder are disabled. Results tabs
  are session-only and are not restored on relaunch.
- Archives are read-only tabs: `zip`/`tar` listings are parsed from the system
  tools, folders are synthesized when the archive omits directory entries, and
  files are extracted through the same tools. Double-clicking a zip/tar file
  opens it as a tab; Quick Look and open extract to a cache first, and
  “Extract to Other Pane” copies files or whole folders out.
- Git support watches the folder's repository (found with
  `git rev-parse --show-toplevel`) and off the main thread parses
  `git status --porcelain -z`. Changed names get a colored letter (`M`, `A`,
  `D`, `R`, `?`, `!`) and the folder rolls up a dot; the status bar shows the
  branch, ahead/behind counts and the number of changes. Git ▸ Stage, Unstage,
  Discard and Commit act on the selection; commit opens a sheet with the staged
  count and an option to stage everything first. Discarding restores tracked
  files and deletes untracked ones after a confirmation, and is not undoable.
- Cloud Drives in the sidebar are the folders kept in sync by the vendors'
  desktop clients (iCloud Drive, Dropbox, Google Drive, OneDrive, Box); they
  open as normal local folders, so sign-in and conflict handling stay with the
  vendor.
- Folder Compare (⇧⌘C) compares both panes recursively by relative path.
  Files match on size and modification time; packages compare as one item.
  Differences can be copied left→right or right→left with one click, creating
  missing subfolders and replacing changed files through a staging name. It
  never deletes extras, so it is a safe one-way copy, not a mirror.
- Remote tabs are session-only. WebDAV/WebDAVS use URLSession with PROPFIND
  listings and GET/PUT/MKCOL/MOVE/COPY/DELETE; Basic auth stays in request
  headers and is never persisted. SFTP is driven through the system `sftp`
  binary inside a pseudo-terminal (password or SSH agent); FTP/FTPS use
  `curl` with credentials passed on stdin, never in argv. Passwords are not
  persisted; saved servers live in Go ▸ Servers and never include credentials.
  Remote panes support browsing, navigation, refresh, Quick Look (download
  cache), Download to Other Pane, Upload to Other Pane, new folder, rename and
  permanent delete (remote mutations are not undoable). Clipboard operations,
  batch rename, compress, advanced search and drag & drop stay local-only.
  FTPS is implemented with explicit TLS but has not yet been verified against
  a live FTPS server.
- Batch rename builds a plan first: template tokens (`{name}`, `{ext}`,
  `{n}`/`{nn}`, `{date}`), find/replace, numbering and a live old/new/status
  preview. Conflicts with existing or duplicate names block Apply. Execution
  stages every source under a temporary name, so name swaps and case-only
  renames never overwrite data; the whole batch is one undo record.
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
| Batch Rename | ⌥⌘R |
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
| Advanced Search | ⇧⌘F |
| Connect to Server | ⌘K |
| Download to Other Pane | ⌥⌘D |
| Upload to Other Pane | ⌥⌘U |
| Compare Folders | ⇧⌘C |
| Open Archive | ⌥⌘O |
| Git Commit | ⌥⌘K |
| Git Stage Selection | ⌥⌘S |
| Git Unstage Selection | ⇧⌥⌘S |
| Extract to Other Pane | ⌥⌘E |
| Settings | ⌘, |
| Show Hidden Files | ⇧⌘. |
| Show Sidebar | ⌃⌘S |
| Single Pane | ⌘\ |
| Swap Panes | ⇧⌘S |

Settings → Keyboard Shortcuts… offers two presets:

- **OpenLift Default** — the Command-key layout above.
- **Classic Commander** — classic two-pane function keys: F2 refresh, F3 view,
  F5 copy, F6 move, ⇧F6 rename, F7 new folder, F8 delete, F12 activity; ⌃U
  swaps panes and ⌥F7 opens advanced search.

Individual commands can be re-recorded after choosing a preset. Switching
presets replaces the custom keys, and the choice is remembered between runs.

## Legal

OpenLift is an independent, clean-room implementation. It contains no
decompiled code, resources, icons, localizations or branding from any
commercial product. Reverse-engineering research, when performed, is used only
to understand observable behaviour and to inform an original design.

## License

MIT — see [`LICENSE`](LICENSE).

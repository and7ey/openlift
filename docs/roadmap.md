# Roadmap

Status legend: ✅ done · 🚧 in progress · ⬜ planned

## M0 — Scaffold ✅

- [x] SwiftPM package (`OpenLiftCore`, `OpenLiftUI`, `OpenLiftApp`, `OpenLift`)
- [x] AppKit application bootstrap
- [x] Main window: sidebar + two panes, split view, toolbar
- [x] Menu bar
- [x] `.app` bundle script, ad-hoc signing
- [x] Dependency-free self-test runner

## M1 — Browser ✅

- [x] Directory listing with metadata
- [x] Sortable columns (name, size, kind, modified), folders first
- [x] Navigation: double-click, back/forward/up/home, path bar, sidebar
- [x] Hidden files toggle
- [x] Live refresh (FSEvents, debounced, off the main thread)
- [x] Window state + favorites persistence
- [x] Tabs per pane (new/close/switch, restored on launch)
- [x] Mounted volumes in the sidebar
- [x] Grouping (kind/name)
- [x] Remember per-folder view settings

## M2 — Operations ✅

- [x] Copy / move between panes (menu) and drag & drop into a pane
- [x] Basic conflict resolution (`replace`, `skip`, `keepBoth`)
- [x] Transfer engine: plan, progress events, per-item policies
- [x] Clipboard: copy, cut, paste (file URLs on the pasteboard, cut moves on paste)
- [x] Conflict dialog with "apply to all" (asked per item, with a checkbox)
- [x] Undo / redo (trash restore, move back, rename back, new folder)
- [x] Activity window with progress and logs
- [x] Cancellation without partial files (staging name + atomic rename)
- [x] Cross-volume move via temporary name (rename, else copy + delete)
- [x] `copyfile(3)` for metadata fidelity (permissions, times, ACLs, xattrs)

## M3 — Comfort ✅

- [x] Quick Look panel and preview (Space, ⌘Y)
- [x] Get Info / inspector (⌘I, multi-selection)
- [x] Open With (menu bar and context menu)
- [x] Search in current folder (live name filter, ⌘F)
- [x] Advanced search (recursive, content, type/extension filters, preview, results tab)
- [x] Create ZIP archive (single item or selection)
- [x] Icon view (`NSCollectionView`)
- [x] Settings window (General, Activity, About)
- [x] Keyboard shortcut customization (recorder, conflict check, defaults)
- [x] Shortcut presets (OpenLift Default, Classic Commander)

## M4 — Stabilization 🚧

- [x] Unit/integration tests (dependency-free runner; XCTest when Xcode is available)
- [x] 100k-file performance target (list ~1.5 s, cached views)
- [x] Permission error dialogs (Full Disk Access shortcut)
- [x] Release build, icon, versioning (0.1.0)
- [ ] (later) Developer ID signing + notarization

## Post-MVP — Remote and advanced ⬜

- [x] SFTP / FTP providers
  - [x] Connection sheet for SFTP, FTP and FTPS (password or SSH agent)
  - [x] Browse, navigate, refresh and show the remote URL
  - [x] Download files and folders to the local pane
  - [x] Upload files and folders to the remote pane
  - [x] New folder, rename and permanent delete on remote panes
  - [x] Remembered server bookmarks (Go ▸ Servers, no passwords)
  - [x] Remote listing parser (UNIX `ls -l` output from SFTP and FTP)
  - [ ] Live FTPS verification and SSH key-file picker
- [x] WebDAV (PROPFIND listing; GET/PUT/MKCOL/MOVE/COPY/DELETE)
- [ ] S3 / Backblaze B2
- [x] Cloud drives via installed desktop sync folders (iCloud, Dropbox, Drive, OneDrive, Box)
  - [ ] Native OAuth providers for machines without the desktop clients
- [x] Folder compare and copy sync (left↔right, no deletions)
- [ ] Archive browsing
- [ ] Git status and actions
- [x] Batch rename (template tokens, find/replace, numbering, preview)
- [ ] Themes

## Engineering notes

- The `FileProvider` boundary is the contract that keeps remote support from
  touching the browser.
- Operations must never run synchronously on the main actor.
- Every destructive operation needs an inverse recorded for undo.
- Prefer small, reviewable commits; each milestone should build and pass
  `swift run OpenLiftSelfTest`.

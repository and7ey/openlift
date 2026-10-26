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

## M3 — Comfort ⬜

- [x] Quick Look panel and preview (Space, ⌘Y)
- [x] Get Info / inspector (⌘I, multi-selection)
- [x] Open With (menu bar and context menu)
- [ ] Search in current folder
- [ ] Create ZIP archive
- [ ] Icon view (`NSCollectionView`)
- [ ] Settings window
- [ ] Keyboard shortcut customization

## M4 — Stabilization ⬜

- [ ] Unit/integration tests (XCTest or swift-testing)
- [ ] 100k-file performance target
- [ ] Permission error dialogs (Full Disk Access)
- [ ] Release build, icon, versioning
- [ ] (later) Developer ID signing + notarization

## Post-MVP — Remote and advanced ⬜

- [ ] SFTP / FTP / FTPS providers
- [ ] WebDAV
- [ ] S3 / Backblaze B2
- [ ] Dropbox / Google Drive / OneDrive
- [ ] Folder sync / compare
- [ ] Archive browsing
- [ ] Git status and actions
- [ ] Batch rename
- [ ] Themes

## Engineering notes

- The `FileProvider` boundary is the contract that keeps remote support from
  touching the browser.
- Operations must never run synchronously on the main actor.
- Every destructive operation needs an inverse recorded for undo.
- Prefer small, reviewable commits; each milestone should build and pass
  `swift run OpenLiftSelfTest`.

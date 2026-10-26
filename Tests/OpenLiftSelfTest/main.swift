import Foundation
import OpenLiftCore

// A dependency-free test runner. XCTest and swift-testing both require a full
// Xcode installation, which is not present on every development machine, so
// the core checks live here and run with `swift run OpenLiftSelfTest`.

var failures = 0
var checks = 0

@MainActor
func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

/// Small lock-free holder for values written from a progress callback.
final class ValueBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

func item(_ name: String, directory: Bool = false, size: Int64 = 0) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        name: name,
        isDirectory: directory,
        size: size
    )
}

func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openlift-selftest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Ordering

let unordered = [item("b.txt"), item("Folder", directory: true), item("a.txt")]
let foldersFirst = FileItemOrdering.sorted(
    unordered,
    by: SortDescriptor(key: .name, ascending: true, foldersFirst: true)
)
check(foldersFirst.map(\.name) == ["Folder", "a.txt", "b.txt"], "folders sort first by name")

let bySize = FileItemOrdering.sorted(
    [item("small", size: 1), item("big", size: 100), item("mid", size: 50)],
    by: SortDescriptor(key: .size, ascending: false, foldersFirst: false)
)
check(bySize.map(\.name) == ["big", "mid", "small"], "size sorts descending")

let groups = FileItemOrdering.grouped(
    [item("A", directory: true), item("B"), item("C", directory: true)],
    by: .kind
)
check(groups.map(\.title) == ["Document", "Folder"], "group titles are stable")
check(groups.first(where: { $0.title == "Folder" })?.items.count == 2, "folders group contains both folders")

// MARK: - Favorites

let encoded = try JSONEncoder().encode(Favorite.defaults)
let decoded = try JSONDecoder().decode([Favorite].self, from: encoded)
check(decoded == Favorite.defaults, "favorites survive a JSON round trip")
check(FavoriteRow.flatten(Favorite.defaults).contains { $0.depth == 1 }, "flatten keeps depth")

let missingURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("openlift-missing-\(UUID().uuidString).json")
check(FavoritesStore(fileURL: missingURL).load() == Favorite.defaults, "missing favorites fall back to defaults")

let tempFavoritesURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("openlift-\(UUID().uuidString).json")
let favoritesStore = FavoritesStore(fileURL: tempFavoritesURL)
var customFavorites = Favorite.defaults
customFavorites.append(Favorite(name: "Temp", path: "/tmp"))
favoritesStore.save(customFavorites)
check(favoritesStore.load() == customFavorites, "favorites persist to disk")
try? FileManager.default.removeItem(at: tempFavoritesURL)

// MARK: - Local provider

let provider = LocalFileProvider()

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))

    let visible = try await provider.list(root)
    check(visible.map(\.name) == ["visible.txt"], "hidden files are skipped by default")

    let all = try await provider.list(root, options: ListOptions(showHidden: true))
    check(Set(all.map(\.name)) == ["visible.txt", ".hidden"], "showHidden returns everything")
} catch {
    failures += 1
    print("FAIL listing: \(error)")
}

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("a.txt")
    let destination = root.appendingPathComponent("b.txt")
    try Data("x".utf8).write(to: source)

    try await provider.move(source, to: destination)
    check(FileManager.default.fileExists(atPath: destination.path), "move writes destination")
    check(!FileManager.default.fileExists(atPath: source.path), "move removes source")

    try await provider.createDirectory(at: root.appendingPathComponent("sub", isDirectory: true))
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("sub").path), "createDirectory")

    try await provider.delete(destination)
    check(!FileManager.default.fileExists(atPath: destination.path), "delete removes file")
} catch {
    failures += 1
    print("FAIL operations: \(error)")
}

// MARK: - Transfers

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceDir = root.appendingPathComponent("A", isDirectory: true)
    let targetDir = root.appendingPathComponent("B", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

    let file = sourceDir.appendingPathComponent("note.txt")
    try Data("hello".utf8).write(to: file)

    let transfer = FileTransfer()

    let copied = await transfer.transfer([file], to: targetDir, kind: .copy, policy: .replace)
    check(copied.transferred.count == 1, "copy transfers one item")
    check(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("note.txt").path), "copy writes destination")
    check(FileManager.default.fileExists(atPath: file.path), "copy keeps source")

    let kept = await transfer.transfer([file], to: targetDir, kind: .copy, policy: .keepBoth)
    check(kept.transferred.first?.lastPathComponent == "note copy.txt", "keepBoth renames the copy")

    let skipped = await transfer.transfer([file], to: targetDir, kind: .copy, policy: .skip)
    check(skipped.skipped.count == 1, "skip leaves the existing item")

    let moved = await transfer.transfer([file], to: targetDir, kind: .move, policy: .replace)
    check(moved.transferred.count == 1, "move transfers one item")
    check(!FileManager.default.fileExists(atPath: file.path), "move removes source")
} catch {
    failures += 1
    print("FAIL transfers: \(error)")
}

// MARK: - Transfer plan, progress, cancellation

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDir = root.appendingPathComponent("src", isDirectory: true)
    let targetDir = root.appendingPathComponent("dst", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

    let nested = sourceDir.appendingPathComponent("folder/sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))
    let top = sourceDir.appendingPathComponent("top.txt")
    try Data("top".utf8).write(to: top)

    // Planning: conflicts, per-item policies, sizes.
    try Data("old".utf8).write(to: targetDir.appendingPathComponent("top.txt"))
    let planner = TransferPlanner()
    let plan = planner.plan(
        sources: [top, sourceDir.appendingPathComponent("folder")],
        to: targetDir,
        kind: .copy,
        policy: .replace
    )
    check(plan.conflicts == [top], "planner reports existing destination names")
    check(plan.itemCount == 2, "planner keeps non-conflicting items")
    check(plan.totalBytes == Int64(3 + 4), "planner sums file sizes")

    let skipPlan = planner.plan(sources: [top], to: targetDir, kind: .copy, policy: .skip)
    check(skipPlan.itemCount == 0 && skipPlan.skipped == [top], "planner drops skipped items")

    let keepPlan = planner.plan(sources: [top], to: targetDir, kind: .copy, policy: .keepBoth)
    check(keepPlan.entries.first?.target.lastPathComponent == "top copy.txt", "planner renames keepBoth copies")

    let mixedPlan = planner.plan(
        sources: [top],
        to: targetDir,
        kind: .copy,
        policy: .skip,
        policies: [top: .replace]
    )
    check(mixedPlan.itemCount == 1, "per-item policy overrides the batch policy")

    // Copy tree with metadata.
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: top.path)
    let copyPlan = planner.plan(
        sources: [sourceDir.appendingPathComponent("folder"), top],
        to: targetDir,
        kind: .copy,
        policy: .replace
    )
    let lastFraction = ValueBox<Double>(0)
    let copyOutcome = TransferExecutor().execute(
        copyPlan,
        kind: .copy,
        progress: { value in lastFraction.value = value.fraction }
    )
    let copiedDeep = targetDir.appendingPathComponent("folder/sub/deep.txt")
    check(FileManager.default.fileExists(atPath: copiedDeep.path), "executor copies a directory tree")
    check(
        (try? String(contentsOf: copiedDeep, encoding: .utf8)) == "deep",
        "executor writes nested contents"
    )
    let copiedTop = targetDir.appendingPathComponent("top.txt")
    check((try? String(contentsOf: copiedTop, encoding: .utf8)) == "top", "executor replaces the target")
    let permissions = (try? FileManager.default.attributesOfItem(atPath: copiedTop.path)[.posixPermissions]) as? Int
    check(permissions == 0o640, "executor copies POSIX permissions")
    check(copyOutcome.transferred.count == 2, "executor reports transferred items")
    check(lastFraction.value == 1, "progress ends at 100%")

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: targetDir.path)
        .filter { $0.contains(".openlift-") }
    check(leftovers.isEmpty, "executor leaves no staging files behind")

    // Move across a volume boundary (forced copy-and-delete path).
    let moveSource = sourceDir.appendingPathComponent("top.txt")
    let movePlan = planner.plan(sources: [moveSource], to: targetDir, kind: .move, policy: .replace)
    let moveOutcome = TransferExecutor(moveStrategy: .copyAndDelete).execute(movePlan, kind: .move)
    check(moveOutcome.transferred.count == 1, "copy-and-delete move completes")
    check(!FileManager.default.fileExists(atPath: moveSource.path), "copy-and-delete move removes the source")
    check((try? String(contentsOf: targetDir.appendingPathComponent("top.txt"), encoding: .utf8)) == "top",
          "copy-and-delete move writes the target")

    // Cancellation inside a large file: nothing partial is left behind.
    let bigDir = root.appendingPathComponent("big", isDirectory: true)
    try FileManager.default.createDirectory(at: bigDir, withIntermediateDirectories: true)
    let big = bigDir.appendingPathComponent("big.bin")
    try Data(count: 16 << 20).write(to: big)
    let bigTargetDir = root.appendingPathComponent("bigdst", isDirectory: true)
    try FileManager.default.createDirectory(at: bigTargetDir, withIntermediateDirectories: true)

    let token = CancellationToken()
    let bigPlan = planner.plan(sources: [big], to: bigTargetDir, kind: .copy, policy: .replace)
    let cancelledOutcome = TransferExecutor().execute(
        bigPlan,
        kind: .copy,
        isCancelled: { token.isCancelled },
        progress: { value in
            if value.bytesCompleted > 0 { token.cancel() }
        }
    )
    check(cancelledOutcome.cancelled, "cancellation is reported")
    check(cancelledOutcome.transferred.isEmpty, "cancelled transfer reports nothing transferred")
    let bigLeftovers = try FileManager.default.contentsOfDirectory(atPath: bigTargetDir.path)
    check(bigLeftovers.isEmpty, "cancelled transfer leaves no partial file")
    check(FileManager.default.fileExists(atPath: big.path), "cancelled copy keeps the source")
} catch {
    failures += 1
    print("FAIL transfer engine: \(error)")
}

// MARK: - Undo records

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let performer = OperationUndo()

    // Move: undoing puts the item back where it came from.
    let from = root.appendingPathComponent("from.txt")
    let to = root.appendingPathComponent("to.txt")
    try Data("payload".utf8).write(to: from)
    try FileManager.default.moveItem(at: from, to: to)
    let moveRecord = FileOperationRecord(kind: .move, pairs: [.init(source: from, target: to)])
    check(moveRecord.title == "Move “from.txt”", "move record has a menu title")
    let moveBack = try await performer.perform(moveRecord, forward: false)
    check(FileManager.default.fileExists(atPath: from.path), "undoing a move restores the source")
    check(!FileManager.default.fileExists(atPath: to.path), "undoing a move removes the target")
    check(moveBack.kind == .move && moveBack.pairs.first?.source == to, "undoing a move yields the reverse move")

    // Redo applies the stored inverse backwards, which moves it forward again.
    let moveForward = try await performer.perform(moveBack, forward: false)
    check(FileManager.default.fileExists(atPath: to.path), "redoing a move writes the target again")
    check(moveForward.pairs.first?.source == from, "redoing a move yields the original move")
    _ = try await performer.perform(moveForward, forward: false)

    // Copy: undoing trashes what was created.
    let copyTarget = root.appendingPathComponent("copy.txt")
    try FileManager.default.copyItem(at: from, to: copyTarget)
    let copyRecord = FileOperationRecord(kind: .copy, pairs: [.init(source: from, target: copyTarget)])
    let copyUndo = try await performer.perform(copyRecord, forward: false)
    check(!FileManager.default.fileExists(atPath: copyTarget.path), "undoing a copy removes the copy")
    check(copyUndo.kind == .trash, "undoing a copy remembers the trashed item")
    if let trashURL = copyUndo.pairs.first?.target {
        check(FileManager.default.fileExists(atPath: trashURL.path), "the copy landed in the Trash")
        try? FileManager.default.removeItem(at: trashURL)
    }

    // Trash: undoing restores the item from the Trash.
    let doomed = root.appendingPathComponent("doomed.txt")
    try Data("bye".utf8).write(to: doomed)
    let trashed = try await LocalFileProvider().trash(doomed)
    let trashRecord = FileOperationRecord(kind: .trash, pairs: [.init(source: doomed, target: trashed)])
    let restoreRecord = try await performer.perform(trashRecord, forward: false)
    check(FileManager.default.fileExists(atPath: doomed.path), "undoing a trash restores the item")
    check(!FileManager.default.fileExists(atPath: trashed.path), "the trashed copy is gone after restore")
    check(restoreRecord.kind == .move, "undoing a trash yields a move out of the Trash")
    let reTrashed = try await performer.perform(restoreRecord, forward: false)
    check(FileManager.default.fileExists(atPath: doomed.path) == false, "redoing a trash removes the item again")
    if let trashURL = reTrashed.pairs.first?.target {
        try? FileManager.default.removeItem(at: trashURL)
    }

    // New folder: undoing removes the folder.
    let folder = root.appendingPathComponent("fresh", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let folderRecord = FileOperationRecord(kind: .createDirectory, pairs: [.init(source: folder, target: folder)])
    let folderUndo = try await performer.perform(folderRecord, forward: false)
    check(!FileManager.default.fileExists(atPath: folder.path), "undoing a new folder removes it")
    if let trashURL = folderUndo.pairs.first?.target {
        try? FileManager.default.removeItem(at: trashURL)
    }
} catch {
    failures += 1
    print("FAIL undo records: \(error)")
}

// MARK: - Per-folder view settings

do {
    let suite = "OpenLiftSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = ViewSettingsStore(defaults: defaults)
    var folderSettings = ViewSettings.default
    folderSettings.sort = SortDescriptor(key: .size, ascending: false, foldersFirst: true)
    folderSettings.group = .kind
    folderSettings.showHidden = true

    store.set(folderSettings, for: "/tmp/openlift-a")
    check(store.settings(for: "/tmp/openlift-a") == folderSettings, "view settings persist per path")
    check(store.settings(for: "/tmp/openlift-b") == nil, "an unseen folder has no stored settings")

    let model = BrowserModel(
        provider: LocalFileProvider(),
        directory: URL(fileURLWithPath: "/tmp/openlift-a", isDirectory: true),
        settings: .default,
        settingsStore: store
    )
    check(model.settings == folderSettings, "browser model adopts stored folder settings")

    store.remove(for: "/tmp/openlift-a")
    check(store.settings(for: "/tmp/openlift-a") == nil, "settings can be removed")
}

// MARK: - Window state with tabs

do {
    let first = PaneState(path: "/tmp", settings: .default)
    let second = PaneState(path: "/Users")
    let state = WindowState(
        frame: CGRect(x: 0, y: 0, width: 900, height: 600),
        left: first,
        right: second,
        leftTabs: [first, second],
        rightTabs: [second],
        leftActiveTab: 1,
        rightActiveTab: 0
    )

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WindowState.self, from: data)
    check(decoded == state, "window state with tabs survives a JSON round trip")
    check(decoded.leftTabs?.count == 2, "both tabs are preserved")

    // Older builds wrote no tab keys at all; those states must still load.
    if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for key in ["leftTabs", "rightTabs", "leftActiveTab", "rightActiveTab"] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(WindowState.self, from: legacyData)
        check(legacy.leftTabs == nil, "legacy window state without tab keys decodes")
        check(legacy.left.path == "/tmp", "legacy window state keeps the pane path")
    } else {
        check(false, "window state encodes as a JSON object")
    }
}

// MARK: - Directory watcher

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let fired = DispatchSemaphore(value: 0)
    let watcher = DirectoryWatcher(debounceInterval: 0.05) { fired.signal() }
    watcher.watch(root)
    // Stream creation is asynchronous, so give the control queue a moment.
    try await Task.sleep(for: .milliseconds(500))

    try Data("change".utf8).write(to: root.appendingPathComponent("created.txt"))
    check(fired.wait(timeout: .now() + 3) == .success, "directory watcher reports a created file")
    watcher.stop()
}

// FSEvents is recursive; a listing only cared about its own level.
do {
    let watched = "/Users/example"
    check(DirectoryWatcher.isRelevantChange(watched, for: watched), "a change to the watched folder itself is relevant")
    check(
        DirectoryWatcher.isRelevantChange("/Users/example/file.txt", for: watched),
        "a change to a direct child is relevant"
    )
    check(
        !DirectoryWatcher.isRelevantChange("/Users/example/Library/Caches/x", for: watched),
        "a change deeper in the tree is ignored"
    )
}

// MARK: - Summary

print("")
print(failures == 0
    ? "PASS — \(checks) checks"
    : "FAILED — \(failures) of \(checks) checks")
if failures > 0 {
    exit(1)
}

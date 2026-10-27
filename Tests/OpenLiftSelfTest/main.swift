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

func zipListing(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
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

func collectSearch(
    _ criteria: SearchCriteria,
    cancellation: CancellationToken = CancellationToken()
) async -> (items: [FileItem], summary: SearchSummary?) {
    var items: [FileItem] = []
    var summary: SearchSummary?
    for await event in SearchEngine().search(criteria, cancellation: cancellation) {
        switch event {
        case .batch(let batch):
            items.append(contentsOf: batch)
        case .finished(let result):
            summary = result
        case .progress:
            break
        }
    }
    return (items, summary)
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

// MARK: - Search filter and archives

do {
    // In-folder search is a name filter, case- and diacritic-insensitive.
    let report = item("Report.txt")
    let photo = item("photo.png", directory: true)
    let second = item("REPORT-2.pdf")
    check(FileItemOrdering.filtered([report, photo, second], by: "report").count == 2, "search filters names case-insensitively")
    check(FileItemOrdering.filtered([report, photo], by: "  ").count == 2, "blank search keeps everything")
    check(FileItemOrdering.filtered([report, photo], by: "zzz").isEmpty, "search can match nothing")

    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("deep".utf8).write(to: folder.appendingPathComponent("deep.txt"))
    let single = root.appendingPathComponent("one.txt")
    try Data("one".utf8).write(to: single)

    let singleDestination = ArchiveCreator.destination(for: [single], in: root)
    check(singleDestination.lastPathComponent == "one.txt.zip", "single file archive is named name.zip")
    let folderDestination = ArchiveCreator.destination(for: [folder], in: root)
    check(folderDestination.lastPathComponent == "folder.zip", "single folder archive is named folder.zip")

    let destination = ArchiveCreator.destination(for: [single, folder], in: root)
    check(destination.lastPathComponent == "Archive.zip", "multi-item archive is Archive.zip")
    let result = try await ArchiveCreator().createArchive(containing: [single, folder], to: destination)
    check(FileManager.default.fileExists(atPath: destination.path), "zip archive is created")
    check(result.itemCount == 2, "zip archive reports its input count")
    let listing = try zipListing(destination)
    check(listing.contains("one.txt"), "zip keeps a selected file at the top level")
    check(listing.contains("folder/deep.txt"), "zip keeps a selected folder and its contents")

    let nextDestination = ArchiveCreator.destination(for: [single, folder], in: root)
    check(nextDestination.lastPathComponent == "Archive copy.zip", "zip naming avoids overwriting an archive")
} catch {
    failures += 1
    print("FAIL search/archives: \(error)")
}

// MARK: - Advanced search

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("folder", isDirectory: true)
    let sub = folder.appendingPathComponent("sub", isDirectory: true)
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    for directory in [folder, sub, empty] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("needle in alpha".utf8).write(to: root.appendingPathComponent("alpha.txt"))
    try Data("other".utf8).write(to: root.appendingPathComponent("beta.md"))
    try Data("needle in gamma".utf8).write(to: folder.appendingPathComponent("gamma.txt"))
    try Data("delta".utf8).write(to: sub.appendingPathComponent("delta.txt"))
    try Data("needle hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))

    // Single-level name search.
    var criteria = SearchCriteria(root: root, nameContains: "alpha", recursive: false)
    var outcome = await collectSearch(criteria)
    check(outcome.items.map(\.url.lastPathComponent) == ["alpha.txt"], "search finds a file by name in one level")
    check(outcome.summary?.matched == 1, "search summary counts matches")

    // Recursive content search skips hidden files by default.
    criteria = SearchCriteria(root: root, contentContains: "needle", recursive: true)
    outcome = await collectSearch(criteria)
    check(Set(outcome.items.map(\.url.lastPathComponent)) == ["alpha.txt", "gamma.txt"], "content search covers subfolders")
    check(!outcome.items.contains { $0.name == ".hidden.txt" }, "content search skips hidden files by default")

    // Including hidden finds the hidden file too.
    criteria.includeHidden = true
    outcome = await collectSearch(criteria)
    check(outcome.items.contains { $0.name == ".hidden.txt" }, "content search can include hidden files")

    // Single-level content search must not descend.
    criteria = SearchCriteria(root: root, contentContains: "needle", recursive: false)
    outcome = await collectSearch(criteria)
    check(outcome.items.map(\.url.lastPathComponent) == ["alpha.txt"], "single-level content search stays in the folder")

    // Folders-only search.
    criteria = SearchCriteria(root: root, recursive: true, itemType: .folders)
    outcome = await collectSearch(criteria)
    check(outcome.items.allSatisfy(\.isDirectory), "folders-only search returns directories")
    check(Set(outcome.items.map(\.url.lastPathComponent)) == ["folder", "sub", "empty"], "folders-only search walks the tree")

    // Extension filter.
    criteria = SearchCriteria(root: root, recursive: true, extensions: ["md"])
    outcome = await collectSearch(criteria)
    check(outcome.items.map(\.url.lastPathComponent) == ["beta.md"], "extension filter limits results")

    // Result cap.
    criteria = SearchCriteria(root: root, recursive: true, maxResults: 1)
    outcome = await collectSearch(criteria)
    check(outcome.items.count == 1 && outcome.summary?.truncated == true, "search stops at the result limit")

    // Cancellation before the scan starts.
    let token = CancellationToken()
    token.cancel()
    outcome = await collectSearch(
        SearchCriteria(root: root, recursive: true),
        cancellation: token
    )
    check(outcome.summary?.cancelled == true, "search reports cancellation")
    check(outcome.items.isEmpty, "cancelled search returns no items")

    // Search results provider drops entries that disappeared since the search.
    let providerFiles = [
        root.appendingPathComponent("alpha.txt"),
        root.appendingPathComponent("beta.md")
    ]
    let providerItems = providerFiles.compactMap { LocalFileProvider().item(at: $0) }
    let provider = SearchResultsProvider(items: providerItems)
    var listed = try await provider.list(root, options: ListOptions(showHidden: false))
    check(listed.count == 2, "results provider lists the captured items")
    try FileManager.default.removeItem(at: providerFiles[0])
    listed = try await provider.list(root, options: ListOptions(showHidden: false))
    check(listed.count == 1, "results provider drops removed items on reload")
} catch {
    failures += 1
    print("FAIL advanced search: \(error)")
}

// MARK: - Batch rename

do {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let alpha = root.appendingPathComponent("alpha.txt")
    let beta = root.appendingPathComponent("beta.txt")
    let gamma = root.appendingPathComponent("gamma.md")
    try Data("A".utf8).write(to: alpha)
    try Data("B".utf8).write(to: beta)
    try Data("G".utf8).write(to: gamma)

    let planner = BatchRenamePlanner()
    var plan = planner.plan(
        urls: [alpha, beta, gamma],
        options: BatchRenameOptions(template: "{name}-{nn}{ext}", startNumber: 1, numberPadding: 2)
    )
    check(plan.entries.map(\.proposedName) == ["alpha-01.txt", "beta-02.txt", "gamma-03.md"], "batch template numbers in name order")

    plan = planner.plan(
        urls: [alpha],
        options: BatchRenameOptions(find: "a", replace: "X")
    )
    check(plan.entries.first?.proposedName == "XlphX.txt", "batch find/replace is case-insensitive by default")

    plan = planner.plan(
        urls: [alpha],
        options: BatchRenameOptions(find: "A", replace: "X", caseSensitive: true)
    )
    check(plan.entries.first?.proposedName == "alpha.txt", "case-sensitive find skips lowercase matches")
    check(plan.hasChanges == false, "an unchanged plan reports no changes")

    let dottedFolder = root.appendingPathComponent("Docs.v1", isDirectory: true)
    try FileManager.default.createDirectory(at: dottedFolder, withIntermediateDirectories: true)
    plan = planner.plan(
        urls: [dottedFolder],
        options: BatchRenameOptions(template: "{name}-{n}")
    )
    check(plan.entries.first?.proposedName == "Docs.v1-1", "folders keep dots in their base name")

    let dirA = root.appendingPathComponent("A", isDirectory: true)
    let dirB = root.appendingPathComponent("B", isDirectory: true)
    try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
    let fileA = dirA.appendingPathComponent("a.txt")
    let fileB = dirB.appendingPathComponent("b.txt")
    try Data("a".utf8).write(to: fileA)
    try Data("b".utf8).write(to: fileB)
    plan = planner.plan(
        urls: [fileA, fileB],
        options: BatchRenameOptions(template: "same.txt")
    )
    check(plan.isValid, "the same new name is allowed in different folders")

    let existing = root.appendingPathComponent("existing.txt")
    try Data("E".utf8).write(to: existing)
    plan = planner.plan(
        urls: [alpha],
        options: BatchRenameOptions(template: "existing.txt")
    )
    check(plan.entries.first?.issue != nil, "batch rename refuses to overwrite an existing name")

    plan = planner.plan(
        urls: [alpha, beta],
        options: BatchRenameOptions(template: "same.txt")
    )
    check(plan.entries.allSatisfy { $0.issue != nil }, "batch rename refuses duplicate proposed names")

    plan = planner.plan(
        urls: [alpha],
        options: BatchRenameOptions(template: "bad/name{ext}")
    )
    check(plan.entries.first?.issue != nil, "batch rename rejects slashes")

    let executablePlan = planner.plan(
        urls: [alpha, beta, gamma],
        options: BatchRenameOptions(template: "{name}-renamed{ext}")
    )
    check(executablePlan.isValid, "a clean plan is valid")
    let pairs = try BatchRenameExecutor().execute(executablePlan)
    check(pairs.count == 3, "executor reports one pair per renamed item")
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("alpha-renamed.txt").path), "executor writes the new name")
    check(!FileManager.default.fileExists(atPath: alpha.path), "executor removes the old name")
    check(
        (try? String(contentsOf: root.appendingPathComponent("beta-renamed.txt"), encoding: .utf8)) == "B",
        "executor preserves contents"
    )

    // Swapping two names must go through staging, not overwrite half-way.
    let swapA = root.appendingPathComponent("swapA.txt")
    let swapB = root.appendingPathComponent("swapB.txt")
    try Data("one".utf8).write(to: swapA)
    try Data("two".utf8).write(to: swapB)
    let swapPlan = BatchRenamePlan(entries: [
        BatchRenameEntry(
            source: swapA,
            originalName: "swapA.txt",
            proposedName: "swapB.txt",
            issue: nil
        ),
        BatchRenameEntry(
            source: swapB,
            originalName: "swapB.txt",
            proposedName: "swapA.txt",
            issue: nil
        )
    ])
    _ = try BatchRenameExecutor().execute(swapPlan)
    check(
        (try? String(contentsOf: swapB, encoding: .utf8)) == "one"
            && (try? String(contentsOf: swapA, encoding: .utf8)) == "two",
        "executor swaps names without losing data"
    )
} catch {
    failures += 1
    print("FAIL batch rename: \(error)")
}

// MARK: - Remote listings

do {
    let base = RemoteURL.make(
        scheme: "sftp",
        username: "demo",
        host: "example.com",
        port: 22,
        path: "/home/demo"
    )
    let parser = UnixListingParser()
    let listing = """
    sftp> ls -la "/home/demo"
    drwx------ 2 demo users          0 Mar 31  2023 pub
    -rw------- 1 demo users        379 Sep 19  2023 readme.txt
    lrwxrwxrwx 1 demo users          8 Aug 20  2004 link -> target.txt
    -rw-r--r-- 1 demo users         12 Oct 27 13:07 .hidden
    total 4
    """
    let items = parser.items(from: listing, base: base, showHidden: false)
    check(items.count == 3, "remote listing skips prompts, totals and hidden files")
    check(items.first(where: { $0.name == "pub" })?.isDirectory == true, "remote listing detects folders")
    check(items.first(where: { $0.name == "readme.txt" })?.size == 379, "remote listing reads sizes")
    check(items.first(where: { $0.name == "link" })?.isSymlink == true, "remote listing detects symlinks")
    check(items.first(where: { $0.name == "link" })?.url.lastPathComponent == "link", "symlink targets are stripped from names")
    check(
        parser.items(from: listing, base: base, showHidden: true).contains { $0.name == ".hidden" },
        "remote listing can include hidden files"
    )

    let ftpListing = """
    lrwxrwxrwx    1 0        0               8 Aug 20  2004 CRYPTO.README -> .message
    -rw-r--r--    1 0        0           17864 Oct 23  2003 MISSING-FILES
    drwxrwxr-x  326 0        3003        12288 Jan 21  2026 gnu
    """
    let ftpItems = parser.items(from: ftpListing, base: base, showHidden: false)
    check(ftpItems.count == 3, "FTP LIST output is parsed with the same parser")
    check(ftpItems.first(where: { $0.name == "gnu" })?.isDirectory == true, "FTP folders are recognized")

    check(base.host == "example.com" && base.user == "demo", "remote URLs keep host and user")
    check(RemoteURL.child(base, "file name.txt").lastPathComponent == "file name.txt", "remote children keep spaces")

    let connection = RemoteConnection(
        proto: .sftp,
        host: "example.com",
        username: "demo",
        password: "secret"
    )
    check(connection.displayName.contains("demo@example.com"), "remote connections have a display name")
    check(RemoteProtocol.ftps.defaultPort == 21, "FTPS uses the FTP port")
}

// MARK: - Remote bookmarks

do {
    let suite = "OpenLiftSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = RemoteBookmarkStore(defaults: defaults, storageKey: "bookmarks")
    let connection = RemoteConnection(
        proto: .ftp,
        host: "example.com",
        port: 2121,
        username: "demo",
        password: "secret",
        path: "/files"
    )
    let bookmark = RemoteBookmark(connection: connection)
    check(bookmark.name.contains("demo@example.com"), "bookmarks have a readable name")
    check(bookmark.connection.password.isEmpty, "bookmarks never keep passwords")

    store.add(bookmark)
    check(store.load().count == 1, "a server bookmark is saved")

    var replacement = RemoteBookmark(connection: connection)
    replacement.name = "Renamed server"
    store.add(replacement)
    check(store.load().count == 1, "saving the same server/path replaces the bookmark")
    check(store.load().first?.name == "Renamed server", "replacement keeps the new label")

    var other = RemoteBookmark(connection: connection)
    other.path = "/other"
    store.add(other)
    check(store.load().count == 2, "different paths create separate bookmarks")

    store.remove(replacement.id)
    check(store.load().count == 1, "bookmarks can be removed")
    store.removeAll()
    check(store.load().isEmpty, "all bookmarks can be forgotten")
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

// MARK: - Activity log

do {
    let log = await MainActor.run { ActivityLog() }
    let first = await MainActor.run {
        log.begin(title: "Copy “a.txt”", detail: "to “Desktop”")
    }
    await MainActor.run {
        log.update(first, detail: "“a.txt” → “Desktop”", fraction: 0.42)
    }
    let running = await MainActor.run { log.entries.first }
    check(running?.status == .running, "activity entry starts running")
    check(running?.fraction == 0.42, "activity entry reports live progress")
    check(running?.detail.hasPrefix("“a.txt”") == true, "activity update changes the detail")
    let runningCount = await MainActor.run { log.runningCount }
    check(runningCount == 1, "activity counts running entries")

    await MainActor.run { log.finish(first, status: .completed) }
    let finished = await MainActor.run { log.entries.first }
    check(finished?.status == .completed, "activity entry can finish")
    check(finished?.fraction == nil, "finished entries drop their progress")
    check(finished?.finishedAt != nil, "finished entries keep a timestamp")

    // Late progress for a finished entry must not resurrect it.
    await MainActor.run { log.update(first, fraction: 0.9) }
    let lateFraction = await MainActor.run { log.entries.first?.fraction }
    check(lateFraction == nil, "finished entries ignore further progress")

    // Newest first, and failures keep their message.
    let second = await MainActor.run { log.begin(title: "Move “b.txt”", detail: "to “Desktop”") }
    await MainActor.run { log.finish(second, status: .failed, message: "Permission denied") }
    let top = await MainActor.run { log.entries.first }
    check(top?.title == "Move “b.txt”", "newest activity entry comes first")
    check(top?.message == "Permission denied", "failed entries keep the reason")

    await MainActor.run { log.clear() }
    let isEmpty = await MainActor.run { log.entries.isEmpty }
    check(isEmpty, "activity log can be cleared")
}

// MARK: - App settings and activity limits

do {
    let suite = "OpenLiftSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = await MainActor.run { AppSettingsStore(defaults: defaults, storageKey: "settings") }
    let initial = await MainActor.run { store.settings }
    check(initial.undoLimit == 50 && initial.activityLimit == 200, "app settings start with defaults")

    await MainActor.run {
        store.update(AppSettings(undoLimit: 25, activityLimit: 80))
    }
    let reloaded = await MainActor.run { AppSettingsStore(defaults: defaults, storageKey: "settings") }
    let persisted = await MainActor.run { reloaded.settings }
    check(persisted.undoLimit == 25, "undo limit persists")
    check(persisted.activityLimit == 80, "activity limit persists")

    let log = await MainActor.run { ActivityLog() }
    await MainActor.run { log.limit = 1 }
    _ = await MainActor.run { log.begin(title: "One", detail: "") }
    _ = await MainActor.run { log.begin(title: "Two", detail: "") }
    let count = await MainActor.run { log.entries.count }
    check(count == 1, "lowering the activity limit trims old entries")
    let newest = await MainActor.run { log.entries.first?.title }
    check(newest == "Two", "trimming keeps the newest entries")
}

// MARK: - Keyboard shortcuts

do {
    let suite = "OpenLiftSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults, storageKey: "shortcuts")

    check(
        store.shortcut(for: .newFolder) == KeyboardShortcut(key: "n", modifiers: [.command, .shift]),
        "new folder has its default shortcut"
    )
    check(
        store.shortcut(for: .rename) == KeyboardShortcut(key: "\r", modifiers: []),
        "rename has its default Return shortcut"
    )

    let custom = KeyboardShortcut(key: "k", modifiers: [.command, .option])
    store.set(custom, for: .newFolder)
    check(store.shortcut(for: .newFolder) == custom, "a custom shortcut replaces the default")
    check(store.isCustomized(.newFolder), "customized commands are marked")
    check(
        store.conflictingCommand(for: KeyboardShortcut(key: "r", modifiers: [.command]), excluding: .newFolder) == .refresh,
        "shortcut conflicts are detected"
    )
    check(
        store.conflictingCommand(for: custom, excluding: .newFolder) == nil,
        "a unique shortcut has no conflict"
    )

    store.set(nil, for: .refresh)
    check(store.shortcut(for: .refresh) == nil, "a shortcut can be removed")
    let reloaded = ShortcutStore(defaults: defaults, storageKey: "shortcuts")
    check(reloaded.shortcut(for: .refresh) == nil, "a removed shortcut stays removed")
    check(reloaded.shortcut(for: .newFolder) == custom, "custom shortcuts persist")

    reloaded.resetAll()
    check(
        reloaded.shortcut(for: .refresh) == KeyboardShortcut(key: "r", modifiers: [.command]),
        "reset restores defaults"
    )
    check(!reloaded.isCustomized(.newFolder), "reset forgets overrides")

    let defaultsList = ShortcutCommand.allCases.compactMap(\.defaultShortcut)
    check(Set(defaultsList).count == defaultsList.count, "default shortcuts are unique")
    check(
        Set(ShortcutCommand.allCases.map(\.title)).count == ShortcutCommand.allCases.count,
        "shortcut command titles are unique"
    )

    // Presets.
    let presetStore = ShortcutStore(defaults: defaults, storageKey: "presets")
    check(presetStore.preset == .standard, "the default preset is OpenLift Default")
    check(
        presetStore.shortcut(for: .newFolder) == KeyboardShortcut(key: "n", modifiers: [.command, .shift]),
        "the default preset uses the standard new-folder key"
    )

    presetStore.setPreset(.classicCommander)
    check(presetStore.preset == .classicCommander, "the classic preset can be selected")
    check(
        presetStore.shortcut(for: .newFolder) == KeyboardShortcut(key: ShortcutKey.f7, modifiers: []),
        "classic new folder is F7"
    )
    check(
        presetStore.shortcut(for: .copyToOtherPane) == KeyboardShortcut(key: ShortcutKey.f5, modifiers: []),
        "classic copy is F5"
    )
    check(
        presetStore.shortcut(for: .moveToTrash) == KeyboardShortcut(key: ShortcutKey.f8, modifiers: []),
        "classic delete is F8"
    )
    check(ShortcutKey.isFunctionKey(ShortcutKey.f5), "function-key spellings are recognized")

    let classicShortcuts = ShortcutCommand.allCases.compactMap { $0.shortcut(in: .classicCommander) }
    check(Set(classicShortcuts).count == classicShortcuts.count, "classic shortcuts are unique")

    let persistedPreset = ShortcutStore(defaults: defaults, storageKey: "presets")
    check(persistedPreset.preset == .classicCommander, "the preset choice persists")

    persistedPreset.set(custom, for: .newFolder)
    check(persistedPreset.shortcut(for: .newFolder) == custom, "a custom key overrides the preset")
    persistedPreset.setPreset(.standard)
    check(
        persistedPreset.shortcut(for: .newFolder) == KeyboardShortcut(key: "n", modifiers: [.command, .shift]),
        "switching preset clears custom overrides"
    )
    check(!persistedPreset.isCustomized(.newFolder), "switching preset forgets overrides")
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

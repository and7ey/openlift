import Foundation
import OpenLiftCore

/// Listing benchmark for large folders.
///
/// Usage: `swift run -c release OpenLiftBench [count]`
/// The fixture is reused at /tmp/openlift-bench-<count> so repeated runs only
/// measure listing, not file creation.
func prepareFixture(count: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openlift-bench-\(count)", isDirectory: true)
    let marker = root.appendingPathComponent(".complete")

    if !FileManager.default.fileExists(atPath: marker.path) {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Creating \(count) files…")
        let start = Date()
        for index in 0..<count {
            let url = root.appendingPathComponent("file-\(index).txt")
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        print("Created in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }
    return root
}

func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let value = try body()
    print("\(label): \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    return value
}

let count = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 100_000
let root = try prepareFixture(count: count)
let provider = LocalFileProvider()
let settings = ViewSettings.default

func timeAsync<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let start = Date()
    let value = try await body()
    print("\(label): \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    return value
}

let items = try await timeAsync("list") {
    try await provider.list(root, options: ListOptions(showHidden: false))
}
precondition(items.count == count, "expected \(count) items, got \(items.count)")

let sorted = time("sort") {
    FileItemOrdering.sorted(items, by: settings.sort)
}
precondition(sorted.count == count)

_ = time("group") {
    FileItemOrdering.grouped(sorted, by: .kind)
}

_ = time("filter") {
    FileItemOrdering.filtered(sorted, by: "999")
}

print("done")

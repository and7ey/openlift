import Testing
import Foundation
@testable import OpenLiftCore

@Suite("File item ordering")
struct FileItemOrderingTests {
    private func item(_ name: String, directory: Bool = false, size: Int64 = 0) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: directory,
            size: size
        )
    }

    @Test func foldersFirstByName() {
        let items = [item("b.txt"), item("Folder", directory: true), item("a.txt")]
        let sorted = FileItemOrdering.sorted(items, by: SortDescriptor(key: .name, ascending: true, foldersFirst: true))
        #expect(sorted.map(\.name) == ["Folder", "a.txt", "b.txt"])
    }

    @Test func sizeDescendingPutsLargestFirst() {
        let items = [item("small", size: 1), item("big", size: 100), item("mid", size: 50)]
        let sorted = FileItemOrdering.sorted(items, by: SortDescriptor(key: .size, ascending: false, foldersFirst: false))
        #expect(sorted.map(\.name) == ["big", "mid", "small"])
    }

    @Test func groupingByKindKeepsStableTitles() {
        let items = [item("A", directory: true), item("B"), item("C", directory: true)]
        let groups = FileItemOrdering.grouped(items, by: .kind)
        #expect(groups.map(\.title) == ["Document", "Folder"])
        #expect(groups.first(where: { $0.title == "Folder" })?.items.count == 2)
    }
}

@Suite("Favorites")
struct FavoriteTests {
    @Test func favoritesRoundTripThroughJSON() throws {
        let favorites = Favorite.defaults
        let data = try JSONEncoder().encode(favorites)
        let decoded = try JSONDecoder().decode([Favorite].self, from: data)
        #expect(decoded == favorites)
    }

    @Test func flattenPreservesDepth() {
        let rows = FavoriteRow.flatten(Favorite.defaults)
        #expect(rows.contains { $0.depth == 1 })
    }
}

@Suite("Favorites store")
struct FavoritesStoreTests {
    @Test func missingFileFallsBackToDefaults() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openlift-missing-\(UUID().uuidString).json")
        let store = FavoritesStore(fileURL: url)
        #expect(store.load() == Favorite.defaults)
    }

    @Test func saveThenLoad() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openlift-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FavoritesStore(fileURL: url)
        var favorites = Favorite.defaults
        favorites.append(Favorite(name: "Temp", path: "/tmp"))
        store.save(favorites)

        #expect(store.load() == favorites)
    }
}

@Suite("Local file provider")
struct LocalFileProviderTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openlift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func listingRespectsHiddenOption() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))

        let provider = LocalFileProvider()
        let visible = try await provider.list(root)
        #expect(visible.map(\.name) == ["visible.txt"])

        let all = try await provider.list(root, options: ListOptions(showHidden: true))
        #expect(Set(all.map(\.name)) == ["visible.txt", ".hidden"])
    }

    @Test func moveAndDelete() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("a.txt")
        let destination = root.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: source)

        let provider = LocalFileProvider()
        try await provider.move(source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))

        try await provider.delete(destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

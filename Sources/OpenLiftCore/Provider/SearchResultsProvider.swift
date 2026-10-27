import Foundation

/// A read-only provider that serves a fixed set of search results.
///
/// It backs a search-results browser tab: listing, sorting, Quick Look and
/// item-level commands work, while operations that would need a real target
/// folder (paste, new folder, navigation) are disabled by the pane.
///
/// `list` filters out entries that no longer exist, so trashing or moving a
/// result from the results tab removes it the next time the pane reloads.
public struct SearchResultsProvider: FileProvider {
    public static let identifierValue = "search-results"

    public let identifier = Self.identifierValue
    public let displayName = "Search Results"

    private let items: [FileItem]

    public init(items: [FileItem]) {
        self.items = items
    }

    public func list(_ directory: URL, options: ListOptions) async throws -> [FileItem] {
        items.filter { item in
            FileManager.default.fileExists(atPath: item.url.path)
                && (options.showHidden || !item.isHidden)
        }
    }

    public func metadata(for url: URL) async throws -> FileItem {
        guard let item = items.first(where: { $0.url == url }) else {
            throw FileProviderError.notFound(url)
        }
        return item
    }

    public func createDirectory(at url: URL) async throws {
        throw FileProviderError.ioFailure(url, underlying: "Not available in search results")
    }

    public func move(_ source: URL, to destination: URL) async throws {
        throw FileProviderError.ioFailure(source, underlying: "Not available in search results")
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        throw FileProviderError.ioFailure(source, underlying: "Not available in search results")
    }

    public func delete(_ url: URL) async throws {
        throw FileProviderError.ioFailure(url, underlying: "Not available in search results")
    }

    public func trash(_ url: URL) async throws -> URL {
        throw FileProviderError.ioFailure(url, underlying: "Not available in search results")
    }

    public func isDirectory(_ url: URL) async -> Bool {
        items.first(where: { $0.url == url })?.isDirectory ?? false
    }
}

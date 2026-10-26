import Foundation

/// Errors surfaced by providers. Kept provider-neutral so a future SFTP
/// provider can report the same vocabulary as the local one.
public enum FileProviderError: Error, LocalizedError, Sendable {
    case notFound(URL)
    case notADirectory(URL)
    case permissionDenied(URL)
    case alreadyExists(URL)
    case ioFailure(URL, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let url):
            return "“\(url.lastPathComponent)” can’t be found."
        case .notADirectory(let url):
            return "“\(url.lastPathComponent)” is not a folder."
        case .permissionDenied(let url):
            return "You don’t have permission to access “\(url.lastPathComponent)”."
        case .alreadyExists(let url):
            return "An item named “\(url.lastPathComponent)” already exists."
        case .ioFailure(let url, let underlying):
            return "The operation on “\(url.lastPathComponent)” failed: \(underlying)"
        }
    }
}

/// A source of files the browser can present.
///
/// The protocol exists from day one even though the MVP only ships
/// `LocalFileProvider`: remote providers must not force a rewrite of the
/// browser, drag & drop or the operation queue.
public protocol FileProvider: Sendable {
    /// Stable identifier, e.g. `local`.
    var identifier: String { get }
    /// Name shown in the UI, e.g. `Macintosh HD`.
    var displayName: String { get }

    func list(_ directory: URL, options: ListOptions) async throws -> [FileItem]
    func metadata(for url: URL) async throws -> FileItem

    func createDirectory(at url: URL) async throws
    func move(_ source: URL, to destination: URL) async throws
    func copy(_ source: URL, to destination: URL) async throws
    func delete(_ url: URL) async throws
    /// Move to Trash, returning the resulting location so it can be undone.
    func trash(_ url: URL) async throws -> URL

    /// Returns true when the URL can be read as a directory.
    func isDirectory(_ url: URL) async -> Bool
}

public extension FileProvider {
    func list(_ directory: URL) async throws -> [FileItem] {
        try await list(directory, options: ListOptions())
    }
}

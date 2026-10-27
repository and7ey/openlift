import Foundation

/// Local-disk provider built on `FileManager`.
///
/// Listing reads a fixed, small set of resource keys in a single call so the
/// cost per directory stays flat. Heavy work happens off the main actor
/// because the methods are `async` and the type is `Sendable`.
public struct LocalFileProvider: FileProvider {
    public let identifier = "local"
    public let displayName: String

    /// `FileManager.default` is not `Sendable`, so it is fetched on demand
    /// rather than stored.
    private var manager: FileManager { .default }

    public init(displayName: String = "Macintosh HD") {
        self.displayName = displayName
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .isPackageKey,
        .isAliasFileKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .typeIdentifierKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey
    ]

    private static let permissionBits: [UInt16: Character] = [
        0o400: "r", 0o200: "w", 0o100: "x",
        0o040: "r", 0o020: "w", 0o010: "x",
        0o004: "r", 0o002: "w", 0o001: "x"
    ]

    public func list(_ directory: URL, options: ListOptions) async throws -> [FileItem] {
        var isDir: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            throw FileProviderError.notFound(directory)
        }
        guard isDir.boolValue else {
            throw FileProviderError.notADirectory(directory)
        }

        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Self.resourceKeys,
                options: options.showHidden ? [] : [.skipsHiddenFiles]
            )
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoPermissionError {
                throw FileProviderError.permissionDenied(directory)
            }
            throw FileProviderError.ioFailure(directory, underlying: error.localizedDescription)
        }

        return entries.compactMap { Self.makeItem(from: $0) }
    }

    public func metadata(for url: URL) async throws -> FileItem {
        guard let item = Self.makeItem(from: url) else {
            throw FileProviderError.notFound(url)
        }
        return item
    }

    /// Synchronous metadata snapshot for callers that already have a URL
    /// (search results, drag previews) and do not want a task hop per item.
    public func item(at url: URL) -> FileItem? {
        Self.makeItem(from: url)
    }

    public func createDirectory(at url: URL) async throws {
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch let error as NSError {
            throw Self.map(error, url: url)
        }
    }

    public func move(_ source: URL, to destination: URL) async throws {
        do {
            try manager.moveItem(at: source, to: destination)
        } catch let error as NSError {
            throw Self.map(error, url: source)
        }
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        do {
            try manager.copyItem(at: source, to: destination)
        } catch let error as NSError {
            throw Self.map(error, url: source)
        }
    }

    public func delete(_ url: URL) async throws {
        do {
            try manager.removeItem(at: url)
        } catch let error as NSError {
            throw Self.map(error, url: url)
        }
    }

    @discardableResult
    public func trash(_ url: URL) async throws -> URL {
        var resulting: NSURL?
        do {
            try manager.trashItem(at: url, resultingItemURL: &resulting)
        } catch let error as NSError {
            throw Self.map(error, url: url)
        }
        return (resulting as URL?) ?? url
    }

    public func isDirectory(_ url: URL) async -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: - Helpers

    private static func makeItem(from url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
            return nil
        }
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let size = values.fileSize.map(Int64.init)
        let permissions = Self.permissions(of: url)

        return FileItem(
            url: url,
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            isDirectory: isDirectory,
            isSymlink: values.isSymbolicLink ?? false,
            isHidden: values.isHidden ?? false,
            isPackage: isPackage,
            isAlias: values.isAliasFile ?? false,
            size: isDirectory ? nil : size,
            modified: values.contentModificationDate,
            created: values.creationDate,
            contentTypeIdentifier: values.typeIdentifier,
            permissions: permissions,
            owner: nil
        )
    }

    /// Permission bits from `stat(2)`.
    ///
    /// Deliberately not `FileManager.attributesOfItem`: that enumerates every
    /// extended attribute with `getxattr`, which can block for seconds on
    /// dataless files (iCloud Drive, cloud-synced folders) and made a listing
    /// appear to hang. `stat` answers instantly and is what the mode column
    /// needs.
    private static func permissions(of url: URL) -> String? {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return String(info.st_mode & 0o777, radix: 8)
    }

    private static func map(_ error: NSError, url: URL) -> FileProviderError {
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .notFound(url)
        case NSFileWriteFileExistsError:
            return .alreadyExists(url)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permissionDenied(url)
        default:
            return .ioFailure(url, underlying: error.localizedDescription)
        }
    }
}

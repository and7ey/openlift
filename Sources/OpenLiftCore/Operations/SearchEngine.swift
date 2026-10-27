import Foundation

/// What to look for and where.
public struct SearchCriteria: Sendable, Equatable {
    public enum ItemType: String, Sendable, CaseIterable {
        case all
        case files
        case folders

        public var title: String {
            switch self {
            case .all: return "Everything"
            case .files: return "Files only"
            case .folders: return "Folders only"
            }
        }
    }

    public var root: URL
    /// Substring matched against the file name. Empty matches every name.
    public var nameContains: String
    /// Substring matched against a file's text. `nil` or empty disables it.
    public var contentContains: String?
    public var recursive: Bool
    public var includeHidden: Bool
    public var itemType: ItemType
    /// Lowercase extensions without dots; empty means any extension.
    public var extensions: [String]
    /// Safety valve for accidental "search everything" runs.
    public var maxResults: Int

    public init(
        root: URL,
        nameContains: String = "",
        contentContains: String? = nil,
        recursive: Bool = true,
        includeHidden: Bool = false,
        itemType: ItemType = .all,
        extensions: [String] = [],
        maxResults: Int = 20_000
    ) {
        self.root = root
        self.nameContains = nameContains
        self.contentContains = contentContains
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.itemType = itemType
        self.extensions = extensions
        self.maxResults = maxResults
    }

    public var trimmedName: String {
        nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedContent: String? {
        guard let content = contentContains?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }
        return content
    }

    public var normalizedExtensions: Set<String> {
        Set(extensions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }.filter { !$0.isEmpty })
    }
}

public struct SearchProgress: Sendable, Equatable {
    public var scanned: Int
    public var matched: Int
    public var currentName: String
    public var finished: Bool

    public init(scanned: Int, matched: Int, currentName: String, finished: Bool) {
        self.scanned = scanned
        self.matched = matched
        self.currentName = currentName
        self.finished = finished
    }
}

public struct SearchSummary: Sendable, Equatable {
    public var scanned: Int
    public var matched: Int
    public var truncated: Bool
    public var cancelled: Bool

    public init(scanned: Int, matched: Int, truncated: Bool, cancelled: Bool) {
        self.scanned = scanned
        self.matched = matched
        self.truncated = truncated
        self.cancelled = cancelled
    }
}

public enum SearchEvent: Sendable {
    case batch([FileItem])
    case progress(SearchProgress)
    case finished(SearchSummary)
}

/// Recursive (or single-level) file search with optional content matching.
///
/// The engine runs in `Task.detached` and yields results in batches, so the
/// window can show progress and stay responsive while a large tree is scanned.
/// Content matching is limited to files under `maxContentBytes` (16 MB) and
/// skips binary data; that keeps "search text in files" useful without reading
/// multi-gigabyte videos.
public struct SearchEngine: Sendable {
    public static let maxContentBytes: Int64 = 16 << 20

    public init() {}

    public func search(
        _ criteria: SearchCriteria,
        cancellation: CancellationToken
    ) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.run(criteria, cancellation: cancellation, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Scan

    private static func run(
        _ criteria: SearchCriteria,
        cancellation: CancellationToken,
        continuation: AsyncStream<SearchEvent>.Continuation
    ) {
        var scanned = 0
        var matched = 0
        var truncated = false
        var batch: [FileItem] = []

        let name = criteria.trimmedName
        let content = criteria.trimmedContent
        let extensions = criteria.normalizedExtensions
        let provider = LocalFileProvider()

        func finish(cancelled: Bool) {
            if !batch.isEmpty {
                continuation.yield(.batch(batch))
                batch.removeAll()
            }
            continuation.yield(.progress(SearchProgress(
                scanned: scanned,
                matched: matched,
                currentName: "",
                finished: true
            )))
            continuation.yield(.finished(SearchSummary(
                scanned: scanned,
                matched: matched,
                truncated: truncated,
                cancelled: cancelled
            )))
        }

        func visit(_ url: URL) -> Bool {
            if cancellation.isCancelled { return false }

            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]) else { return true }

            let isDirectory = values.isDirectory ?? false
            let isRegularFile = values.isRegularFile ?? false

            scanned += 1

            // A content query can only match files; folders never contain text.
            let typeMatches: Bool
            switch criteria.itemType {
            case .all: typeMatches = content == nil ? true : isRegularFile
            case .files: typeMatches = isRegularFile
            case .folders: typeMatches = isDirectory && content == nil
            }

            let extensionMatches = extensions.isEmpty
                || extensions.contains(url.pathExtension.lowercased())
            let nameMatches = name.isEmpty || url.lastPathComponent.localizedStandardContains(name)

            var contentMatches = true
            if typeMatches, isRegularFile, let content, extensionMatches, nameMatches {
                contentMatches = fileContains(
                    content,
                    at: url,
                    size: values.fileSize,
                    maxBytes: maxContentBytes
                )
            }

            if typeMatches, extensionMatches, nameMatches, contentMatches,
               let item = provider.item(at: url) {
                batch.append(item)
                matched += 1
                if batch.count >= 200 {
                    continuation.yield(.batch(batch))
                    batch.removeAll()
                }
                if matched >= criteria.maxResults {
                    truncated = true
                    return false
                }
            }

            if scanned % 500 == 0 {
                continuation.yield(.progress(SearchProgress(
                    scanned: scanned,
                    matched: matched,
                    currentName: url.lastPathComponent,
                    finished: false
                )))
            }
            return true
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]

        if criteria.recursive {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !criteria.includeHidden {
                options.insert(.skipsHiddenFiles)
            }
            guard let enumerator = FileManager.default.enumerator(
                at: criteria.root,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: { _, _ in true }
            ) else {
                finish(cancelled: false)
                return
            }

            for case let url as URL in enumerator {
                if !visit(url) {
                    break
                }
            }
        } else {
            var options: FileManager.DirectoryEnumerationOptions = []
            if !criteria.includeHidden {
                options.insert(.skipsHiddenFiles)
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: criteria.root,
                includingPropertiesForKeys: keys,
                options: options
            )) ?? []
            for url in children {
                if !visit(url) {
                    break
                }
            }
        }

        finish(cancelled: cancellation.isCancelled)
    }

    // MARK: - Content

    private static func fileContains(
        _ needle: String,
        at url: URL,
        size: Int?,
        maxBytes: Int64
    ) -> Bool {
        guard let size, Int64(size) <= maxBytes else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: Int(size)), !data.isEmpty else {
            return false
        }
        // Skip obvious binaries rather than decoding megabytes of noise.
        if data.prefix(4096).contains(0) { return false }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else { return false }
        return text.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

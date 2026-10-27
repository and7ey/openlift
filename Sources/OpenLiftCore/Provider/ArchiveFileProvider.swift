import Foundation
import UniformTypeIdentifiers

public enum ArchiveFormat: String, Sendable {
    case zip
    case tar

    public static func detect(_ url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") {
            return .tar
        }
        return nil
    }
}

public struct ArchiveEntry: Sendable, Hashable {
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public init(path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// Lists and extracts local zip/tar archives using the system tools.
public struct ArchiveReader: Sendable {
    public let url: URL
    public let format: ArchiveFormat

    public init(url: URL) throws {
        guard let format = ArchiveFormat.detect(url) else {
            throw ArchiveError.unsupportedFormat(url)
        }
        self.url = url
        self.format = format
    }

    public func entries() async throws -> [ArchiveEntry] {
        try await Task.detached(priority: .userInitiated) {
            try listSync()
        }.value
    }

    public func extract(_ path: String, to local: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try extractSync(path, to: local)
        }.value
    }

    // MARK: - Sync work

    private func listSync() throws -> [ArchiveEntry] {
        let arguments: [String]
        switch format {
        case .zip: arguments = ["-l", url.path]
        case .tar: arguments = ["-tvf", url.path]
        }
        let output = try run(tool: format == .zip ? "/usr/bin/unzip" : "/usr/bin/tar", arguments: arguments)

        var parsed: [ArchiveEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            if let entry = parse(text) {
                parsed.append(entry)
            }
        }

        // Archives do not always store directory entries; synthesize them.
        var byPath: [String: ArchiveEntry] = [:]
        for entry in parsed {
            byPath[entry.path] = entry
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                if byPath[parent] == nil {
                    byPath[parent] = ArchiveEntry(path: parent, isDirectory: true, size: 0, modified: nil)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func extractSync(_ path: String, to local: URL) throws {
        let entries = try listSync()
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ArchiveError.entryNotFound(path)
        }

        if entry.isDirectory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let prefix = path + "/"
            for child in entries where child.path.hasPrefix(prefix) {
                let relative = String(child.path.dropFirst(prefix.count))
                let target = local.appendingPathComponent(relative)
                if child.isDirectory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try extractFile(child.path, to: target)
                }
            }
        } else {
            try extractFile(path, to: local)
        }
    }

    private func extractFile(_ path: String, to local: URL) throws {
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let arguments: [String]
        switch format {
        case .zip: arguments = ["-p", url.path, path]
        case .tar:
            let tarPath = path.hasPrefix("./") ? path : "./" + path
            arguments = ["-xOf", url.path, tarPath]
        }
        let data = try runData(tool: format == .zip ? "/usr/bin/unzip" : "/usr/bin/tar", arguments: arguments)
        try data.write(to: local)
    }

    private func parse(_ line: String) -> ArchiveEntry? {
        switch format {
        case .zip:
            let pattern = #"^\s*(\d+)\s+(\d{2}-\d{2}-\d{4})\s+(\d{2}:\d{2})\s+(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let sizeRange = Range(match.range(at: 1), in: line),
                  let dateRange = Range(match.range(at: 2), in: line),
                  let timeRange = Range(match.range(at: 3), in: line),
                  let nameRange = Range(match.range(at: 4), in: line) else { return nil }
            let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
            let date = zipDateFormatter.date(from: "\(line[dateRange]) \(line[timeRange])")
            return makeEntry(name: name, size: Int64(line[sizeRange]) ?? 0, modified: date)

        case .tar:
            let pattern = #"^([dl-][rwxStTs-]{9})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let modeRange = Range(match.range(at: 1), in: line),
                  let sizeRange = Range(match.range(at: 2), in: line),
                  let dateRange = Range(match.range(at: 3), in: line),
                  let nameRange = Range(match.range(at: 4), in: line) else { return nil }
            let name = String(line[nameRange])
            return makeEntry(
                name: name,
                isDirectory: line[modeRange].hasPrefix("d"),
                size: Int64(line[sizeRange]) ?? 0,
                modified: parseTarDate(String(line[dateRange]))
            )
        }
    }

    private func makeEntry(
        name rawName: String,
        isDirectory: Bool = false,
        size: Int64,
        modified: Date?
    ) -> ArchiveEntry? {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("./") { name = String(name.dropFirst(2)) }
        let directory = isDirectory || name.hasSuffix("/")
        while name.hasSuffix("/") { name.removeLast() }
        guard !name.isEmpty, name != "." else { return nil }
        return ArchiveEntry(path: name, isDirectory: directory, size: directory ? 0 : size, modified: modified)
    }

    private func parseTarDate(_ text: String) -> Date? {
        if text.contains(":") {
            if let date = tarShortDateFormatter.date(from: text) {
                let year = Calendar.current.component(.year, from: Date())
                return Calendar.current.date(bySetting: .year, value: year, of: date) ?? date
            }
            return nil
        }
        return tarLongDateFormatter.date(from: text)
    }

    private func run(tool: String, arguments: [String]) throws -> String {
        String(decoding: try runData(tool: tool, arguments: arguments), as: UTF8.self)
    }

    private func runData(tool: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ArchiveError.toolFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.toolFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return data
    }

    private let zipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        return formatter
    }()

    private let tarShortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    private let tarLongDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()
}

public enum ArchiveError: Error, LocalizedError {
    case unsupportedFormat(URL)
    case entryNotFound(String)
    case toolFailed(String)
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            return "“\(url.lastPathComponent)” is not a supported archive."
        case .entryNotFound(let path):
            return "“\(path)” was not found in the archive."
        case .toolFailed(let message):
            return "The archive operation failed: \(message)"
        case .readOnly:
            return "Archives are read-only."
        }
    }
}

/// Read-only provider that browses an archive as a folder tree.
public struct ArchiveFileProvider: FileProvider {
    public static let identifierValue = "archive"

    public let identifier = Self.identifierValue
    public let displayName: String
    public let archiveURL: URL
    public let format: ArchiveFormat
    private let entries: [ArchiveEntry]
    private let rootURL: URL
    private let reader: ArchiveReader

    public init(reader: ArchiveReader, entries: [ArchiveEntry], displayName: String? = nil) {
        self.reader = reader
        archiveURL = reader.url
        format = reader.format
        self.entries = entries
        self.displayName = displayName ?? "Archive: \(reader.url.lastPathComponent)"
        rootURL = URL(string: "archive:///\(UUID().uuidString)/")!
    }

    public var root: URL { rootURL }

    public func list(_ directory: URL, options: ListOptions) async throws -> [FileItem] {
        let path = internalPath(directory)
        let prefix = path.isEmpty ? "" : path + "/"
        var children: [String: ArchiveEntry] = [:]
        for entry in entries {
            guard entry.path.hasPrefix(prefix) else { continue }
            let remainder = String(entry.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }
            let immediate = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard !immediate.isEmpty else { continue }
            let childPath = prefix + immediate
            if let known = entries.first(where: { $0.path == childPath }) {
                children[childPath] = known
            } else if children[childPath] == nil {
                children[childPath] = ArchiveEntry(path: childPath, isDirectory: true, size: 0, modified: nil)
            }
        }
        return children.values
            .filter { entry in
                guard !options.showHidden else { return true }
                let name = entry.path.split(separator: "/").last.map(String.init) ?? ""
                return !name.hasPrefix(".")
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { item(for: $0) }
    }

    public func metadata(for url: URL) async throws -> FileItem {
        let path = internalPath(url)
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw FileProviderError.notFound(url)
        }
        return item(for: entry)
    }

    public func extract(_ path: String, to local: URL) async throws {
        try await reader.extract(path, to: local)
    }

    /// Public so the browser can display the path inside the archive.
    public func relativePath(for url: URL) -> String {
        relativePath(url)
    }

    public func createDirectory(at url: URL) async throws { throw ArchiveError.readOnly }
    public func move(_ source: URL, to destination: URL) async throws { throw ArchiveError.readOnly }
    public func copy(_ source: URL, to destination: URL) async throws { throw ArchiveError.readOnly }
    public func delete(_ url: URL) async throws { throw ArchiveError.readOnly }
    public func trash(_ url: URL) async throws -> URL { throw ArchiveError.readOnly }
    public func isDirectory(_ url: URL) async -> Bool {
        entries.first(where: { $0.path == internalPath(url) })?.isDirectory ?? false
    }

    private func item(for entry: ArchiveEntry) -> FileItem {
        FileItem(
            url: url(for: entry.path),
            name: (entry.path as NSString).lastPathComponent,
            isDirectory: entry.isDirectory,
            isSymlink: false,
            isHidden: (entry.path as NSString).lastPathComponent.hasPrefix("."),
            isPackage: false,
            isAlias: false,
            size: entry.isDirectory ? nil : entry.size,
            modified: entry.modified,
            created: nil,
            contentTypeIdentifier: entry.isDirectory
                ? UTType.folder.identifier
                : UTType(filenameExtension: (entry.path as NSString).pathExtension)?.identifier
        )
    }

    private func url(for path: String) -> URL {
        var url = rootURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func internalPath(_ url: URL) -> String {
        let rootPath = rootURL.path
        let path = url.path
        guard path.hasPrefix(rootPath) else { return "" }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func relativePath(_ url: URL) -> String {
        internalPath(url)
    }
}

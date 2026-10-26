import Foundation

/// Creates ZIP archives with the system `zip` tool.
///
/// The archive keeps the selected items at its top level (a selected folder
/// keeps its own name, as Finder does), symbolic links stay links, and the
/// work runs off the main actor, so compressing a large folder does not block
/// the browser.
public struct ArchiveCreator: Sendable {
    public struct Result: Sendable {
        public let url: URL
        public let itemCount: Int

        public init(url: URL, itemCount: Int) {
            self.url = url
            self.itemCount = itemCount
        }
    }

    public enum CreateError: Error, LocalizedError {
        case noSelection
        case toolFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSelection:
                return "There is nothing to compress."
            case .toolFailed(let message):
                return "The archive could not be created: \(message)"
            }
        }
    }

    public init() {}

    /// Default archive name next to the selection: `name.zip` for one item,
    /// `Archive.zip` for several, never overwriting an existing archive.
    public static func destination(for sources: [URL], in directory: URL) -> URL {
        guard let first = sources.first else {
            return directory.appendingPathComponent("Archive.zip")
        }
        let candidate: URL
        if sources.count == 1 {
            candidate = directory.appendingPathComponent(first.lastPathComponent + ".zip")
        } else {
            candidate = directory.appendingPathComponent("Archive.zip")
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            return FileTransfer.uniqueDestination(for: candidate)
        }
        return candidate
    }

    public func createArchive(containing sources: [URL], to destination: URL) async throws -> Result {
        guard !sources.isEmpty else { throw CreateError.noSelection }

        return try await Task.detached(priority: .userInitiated) {
            try Self.runZip(sources: sources, destination: destination)
        }.value
    }

    private static func runZip(sources: [URL], destination: URL) throws -> Result {
        let parent = commonParent(of: sources)
        let parentComponents = parent.pathComponents
        let arguments = sources.map { url -> String in
            let components = url.pathComponents
            guard components.count > parentComponents.count else { return url.lastPathComponent }
            return components.dropFirst(parentComponents.count).joined(separator: "/")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = parent
        // -r recurse into folders, -q quiet, -y store symbolic links as links,
        // -X drop extra file attributes (no __MACOSX noise).
        process.arguments = ["-r", "-q", "-y", "-X", destination.path] + arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw CreateError.toolFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: destination)
            throw CreateError.toolFailed(message.isEmpty ? "zip exited with code \(process.terminationStatus)" : message)
        }

        return Result(url: destination, itemCount: sources.count)
    }

    /// Deepest folder that contains every source, so relative names in the
    /// archive have no leading path.
    private static func commonParent(of sources: [URL]) -> URL {
        guard let first = sources.first else {
            return URL(fileURLWithPath: "/")
        }
        var components = first.deletingLastPathComponent().standardizedFileURL.pathComponents
        for url in sources.dropFirst() {
            let other = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var shared = 0
            while shared < components.count, shared < other.count, components[shared] == other[shared] {
                shared += 1
            }
            components = Array(components.prefix(shared))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: components))
    }
}

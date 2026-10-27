import Foundation
import UniformTypeIdentifiers

/// Protocols supported by the first remote provider.
public enum RemoteProtocol: String, CaseIterable, Codable, Sendable {
    case sftp
    case ftp
    case ftps
    case webdav
    case webdavs

    public var title: String {
        switch self {
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        case .webdav: return "WebDAV"
        case .webdavs: return "WebDAV (HTTPS)"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftp, .ftps: return 21
        case .webdav: return 80
        case .webdavs: return 443
        }
    }

    public var urlScheme: String {
        switch self {
        case .sftp: return "sftp"
        case .ftp, .ftps: return "ftp"
        case .webdav: return "http"
        case .webdavs: return "https"
        }
    }

    public var isTLS: Bool { self == .ftps || self == .webdavs }
}

public struct RemoteConnection: Sendable, Equatable {
    public var proto: RemoteProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var path: String

    public init(
        proto: RemoteProtocol,
        host: String,
        port: Int? = nil,
        username: String = "",
        password: String = "",
        path: String = "/"
    ) {
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.username = username
        self.password = password
        self.path = path
    }

    public var displayName: String {
        let name = username.isEmpty ? host : "\(username)@\(host)"
        return "\(proto.title) · \(name)"
    }

    public var rootURL: URL {
        RemoteURL.make(
            scheme: proto.urlScheme,
            username: username,
            host: host,
            port: port,
            path: path
        )
    }
}

public enum RemoteURL {
    public static func make(
        scheme: String,
        username: String,
        host: String,
        port: Int,
        path: String
    ) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        if !username.isEmpty {
            components.user = username
        }
        var clean = path
        if clean.isEmpty { clean = "/" }
        if !clean.hasPrefix("/") { clean = "/" + clean }
        components.percentEncodedPath = clean.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? clean
        return components.url ?? URL(fileURLWithPath: "/")
    }

    public static func remotePath(_ url: URL) -> String {
        let path = url.path
        return path.isEmpty ? "/" : path
    }

    public static func child(_ directory: URL, _ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

/// Opens a provider for a connection; the password or SSH agent is used for
/// the lifetime of the provider only (nothing is persisted).
public enum RemoteProviderFactory {
    public static func make(_ connection: RemoteConnection) -> any FileProvider {
        switch connection.proto {
        case .sftp:
            return SFTPRemoteProvider(connection: connection)
        case .ftp, .ftps:
            return FTPRemoteProvider(connection: connection)
        case .webdav, .webdavs:
            return WebDAVRemoteProvider(connection: connection)
        }
    }
}

/// Optional capability used by remote panes to move bytes between a remote
/// server and the local disk.
public protocol RemoteFileTransferring: Sendable {
    func download(_ remote: URL, to local: URL) async throws
    func upload(_ local: URL, to remote: URL) async throws
}

// MARK: - Listing parser

/// Parses UNIX `ls -l`/`ls -la` output (SFTP servers and FTP LIST often use it).
public struct UnixListingParser: Sendable {
    public init() {}

    public func items(from output: String, base: URL, showHidden: Bool) -> [FileItem] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(line: String($0), base: base, showHidden: showHidden) }
    }

    private func parse(line rawLine: String, base: URL, showHidden: Bool) -> FileItem? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              !line.hasPrefix("total "),
              !line.hasPrefix("sftp>"),
              !line.hasPrefix("curl:") else { return nil }

        let pattern = #"^([bcdlps-][rwxStTs-]{9})[+@]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let mode = group(1),
              let sizeText = group(2),
              let dateText = group(3),
              var name = group(4) else { return nil }

        if let targetRange = name.range(of: " -> ") {
            name = String(name[..<targetRange.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        if !showHidden, name.hasPrefix(".") { return nil }

        let isDirectory = mode.hasPrefix("d")
        let isSymlink = mode.hasPrefix("l")
        let url = RemoteURL.child(base, name)
        let ext = (name as NSString).pathExtension
        let contentType = isDirectory
            ? UTType.folder.identifier
            : UTType(filenameExtension: ext)?.identifier

        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isHidden: name.hasPrefix("."),
            isPackage: false,
            isAlias: isSymlink,
            size: isDirectory ? nil : Int64(sizeText),
            modified: Self.parseDate(dateText),
            created: nil,
            contentTypeIdentifier: contentType,
            permissions: mode,
            owner: nil
        )
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()

    private static func parseDate(_ text: String) -> Date? {
        if text.contains(":") {
            guard let date = shortDateFormatter.date(from: text) else { return nil }
            let calendar = Calendar.current
            let year = calendar.component(.year, from: Date())
            return calendar.date(bySetting: .year, value: year, of: date) ?? date
        }
        return longDateFormatter.date(from: text)
    }
}

// MARK: - SFTP

public struct SFTPRemoteProvider: FileProvider, RemoteFileTransferring {
    public let identifier = "remote:sftp"
    public let displayName: String

    private let connection: RemoteConnection
    private let parser = UnixListingParser()

    public init(connection: RemoteConnection) {
        self.connection = connection
        displayName = connection.displayName
    }

    public func list(_ directory: URL, options: ListOptions) async throws -> [FileItem] {
        let path = RemoteURL.remotePath(directory)
        let output = try await run(["ls -la \(quote(path))"])
        try ensureHealthy(output)
        let cleaned = output.replacingOccurrences(of: "\r", with: "")
        let items = parser.items(from: cleaned, base: directory, showHidden: options.showHidden)
        return items
    }

    public func metadata(for url: URL) async throws -> FileItem {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let items = try await list(parent, options: ListOptions(showHidden: true))
        guard let item = items.first(where: { $0.name == name }) else {
            throw FileProviderError.notFound(url)
        }
        return item
    }

    public func createDirectory(at url: URL) async throws {
        _ = try await run(["mkdir \(quote(RemoteURL.remotePath(url)))"])
    }

    public func move(_ source: URL, to destination: URL) async throws {
        _ = try await run([
            "rename \(quote(RemoteURL.remotePath(source))) \(quote(RemoteURL.remotePath(destination)))"
        ])
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        throw FileProviderError.ioFailure(source, underlying: "Remote copy is not supported yet")
    }

    public func delete(_ url: URL) async throws {
        let path = RemoteURL.remotePath(url)
        if await isDirectory(url) {
            let children = try await list(url, options: ListOptions(showHidden: true))
            for child in children {
                try await delete(child.url)
            }
            _ = try await run(["rmdir \(quote(path))"])
        } else {
            _ = try await run(["rm \(quote(path))"])
        }
    }

    public func trash(_ url: URL) async throws -> URL {
        throw FileProviderError.ioFailure(
            url,
            underlying: "Remote items are deleted permanently; the Trash is local-only"
        )
    }

    public func isDirectory(_ url: URL) async -> Bool {
        let path = RemoteURL.remotePath(url)
        guard let output = try? await run(["ls -ld \(quote(path))"]) else { return false }
        let line = output
            .split(separator: "\n")
            .first(where: { !$0.hasPrefix("sftp>") }) ?? ""
        return line.hasPrefix("d")
    }

    // MARK: Transfers

    public func download(_ remote: URL, to local: URL) async throws {
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staged = local.deletingLastPathComponent()
            .appendingPathComponent(".openlift-download-\(UUID().uuidString.prefix(8)).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }

        _ = try await run([
            "get -p \(quote(RemoteURL.remotePath(remote))) \(quote(staged.path))"
        ])
        let manager = FileManager.default
        if manager.fileExists(atPath: local.path) {
            try manager.removeItem(at: local)
        }
        try manager.moveItem(at: staged, to: local)
    }

    public func upload(_ local: URL, to remote: URL) async throws {
        let destination = RemoteURL.remotePath(remote)
        let staged = destination + ".openlift-\(UUID().uuidString.prefix(8)).tmp"
        _ = try await run([
            "put -p \(quote(local.path)) \(quote(staged))",
            "rename \(quote(staged)) \(quote(destination))"
        ])
    }

    // MARK: Transport

    private func run(_ commands: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.runSync(commands)
        }.value
    }

    private func runSync(_ commands: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")

        var sftpArguments = [
            "-q",
            "-P", String(connection.port),
            "-oStrictHostKeyChecking=accept-new",
            "-oConnectTimeout=20",
            "-oNumberOfPasswordPrompts=1"
        ]
        if connection.password.isEmpty {
            sftpArguments.append("-oBatchMode=yes")
            sftpArguments.append("-oPreferredAuthentications=publickey")
        } else {
            sftpArguments.append("-oBatchMode=no")
            sftpArguments.append("-oPreferredAuthentications=password,keyboard-interactive")
        }
        let userHost = connection.username.isEmpty
            ? connection.host
            : "\(connection.username)@\(connection.host)"
        sftpArguments.append(userHost)

        process.arguments = ["-q", "/dev/null", "/usr/bin/sftp"] + sftpArguments

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw FileProviderError.ioFailure(connection.rootURL, underlying: error.localizedDescription)
        }
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let reader = PTYReader(handle: output.fileHandleForReading, writer: input.fileHandleForWriting)
        try reader.login(password: connection.password, timeout: 30)

        var result = ""
        for command in commands {
            result += try reader.command(command, timeout: 60)
        }
        reader.close()

        process.waitUntilExit()
        if process.terminationStatus != 0, result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileProviderError.ioFailure(connection.rootURL, underlying: "SFTP command failed")
        }
        return result
    }

    private func ensureHealthy(_ output: String) throws {
        let lower = output.lowercased()
        let failures = ["permission denied", "authentication failed", "couldn't", "no such file", "failure"]
        if failures.contains(where: { lower.contains($0) }) {
            throw FileProviderError.ioFailure(connection.rootURL, underlying: cleanError(output))
        }
    }

    private func cleanError(_ output: String) -> String {
        output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(3)
            .joined(separator: " ")
    }

    private func quote(_ path: String) -> String {
        "\"" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Drives `sftp` through the pseudo-terminal created by `/usr/bin/script`.
///
/// `sftp`'s batch mode never asks for a password, and askpass is ignored in a
/// GUI process without a controlling terminal. A pty lets us answer the host
/// key and password prompts explicitly, then feed commands and read until the
/// next `sftp>` prompt.
private final class PTYReader {
    private let handle: FileHandle
    private let writer: FileHandle
    private var buffer = ""

    init(handle: FileHandle, writer: FileHandle) {
        self.handle = handle
        self.writer = writer
    }

    func login(password: String, timeout: TimeInterval) throws {
        for _ in 0..<8 {
            let (text, marker) = try readUntilAny(
                ["password:", "yes/no", "sftp>"],
                timeout: timeout
            )
            let lower = text.lowercased()
            if lower.contains("permission denied") || lower.contains("connection closed") {
                throw FileProviderError.ioFailure(
                    URL(fileURLWithPath: "/"),
                    underlying: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            if marker == "password:" {
                guard !password.isEmpty else {
                    throw FileProviderError.ioFailure(
                        URL(fileURLWithPath: "/"),
                        underlying: "The server requires a password"
                    )
                }
                write(password + "\n")
                continue
            }
            if marker == "yes/no" {
                write("yes\n")
                continue
            }
            if marker == "sftp>" {
                return
            }
        }
        throw FileProviderError.ioFailure(
            URL(fileURLWithPath: "/"),
            underlying: "SFTP login timed out"
        )
    }

    func command(_ command: String, timeout: TimeInterval) throws -> String {
        write(command + "\n")
        let text = try readUntil("sftp>", timeout: timeout)
        let lower = text.lowercased()
        if lower.contains("couldn't") || lower.contains("no such file")
            || lower.contains("permission denied") || lower.contains("failure") {
            throw FileProviderError.ioFailure(
                URL(fileURLWithPath: "/"),
                underlying: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return text
    }

    func close() {
        write("exit\n")
    }

    // MARK: - Buffered reads

    private func readUntil(_ marker: String, timeout: TimeInterval) throws -> String {
        let (text, _) = try readUntilAny([marker], timeout: timeout)
        return text
    }

    private func readUntilAny(
        _ markers: [String],
        timeout: TimeInterval
    ) throws -> (text: String, marker: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for marker in markers {
                if let range = buffer.range(of: marker) {
                    let text = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    return (text, marker)
                }
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw FileProviderError.ioFailure(
                    URL(fileURLWithPath: "/"),
                    underlying: "SFTP timed out waiting for \(markers.joined(separator: " / "))"
                )
            }

            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = poll(&descriptor, 1, Int32(min(remaining, 0.2) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw FileProviderError.ioFailure(
                    URL(fileURLWithPath: "/"),
                    underlying: "SFTP read failed"
                )
            }
            if ready == 0 { continue }

            let data = handle.availableData
            if data.isEmpty {
                throw FileProviderError.ioFailure(
                    URL(fileURLWithPath: "/"),
                    underlying: "SFTP connection closed"
                )
            }
            buffer += String(decoding: data, as: UTF8.self)
        }
    }

    private func write(_ text: String) {
        writer.write(Data(text.utf8))
    }
}

// MARK: - FTP / FTPS

public struct FTPRemoteProvider: FileProvider, RemoteFileTransferring {
    public let identifier: String
    public let displayName: String

    private let connection: RemoteConnection
    private let parser = UnixListingParser()

    public init(connection: RemoteConnection) {
        self.connection = connection
        identifier = "remote:\(connection.proto.rawValue)"
        displayName = connection.displayName
    }

    public func list(_ directory: URL, options: ListOptions) async throws -> [FileItem] {
        let url = ftpURL(directory, directory: true)
        let output = try await run(url: url, extra: [])
        let cleaned = output.replacingOccurrences(of: "\r", with: "")
        let items = parser.items(from: cleaned, base: directory, showHidden: options.showHidden)
        if items.isEmpty, output.lowercased().contains("curl:") {
            throw FileProviderError.ioFailure(directory, underlying: output)
        }
        return items
    }

    public func metadata(for url: URL) async throws -> FileItem {
        let items = try await list(url.deletingLastPathComponent(), options: ListOptions(showHidden: true))
        guard let item = items.first(where: { $0.name == url.lastPathComponent }) else {
            throw FileProviderError.notFound(url)
        }
        return item
    }

    public func createDirectory(at url: URL) async throws {
        _ = try await run(
            url: commandURL,
            extra: ["quote = \"MKD \(escapeConfig(url.path))\""]
        )
    }

    public func move(_ source: URL, to destination: URL) async throws {
        _ = try await run(
            url: commandURL,
            extra: [
                "quote = \"RNFR \(escapeConfig(source.path))\"",
                "quote = \"RNTO \(escapeConfig(destination.path))\""
            ]
        )
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        throw FileProviderError.ioFailure(source, underlying: "Remote copy is not supported yet")
    }

    public func delete(_ url: URL) async throws {
        if await isDirectory(url) {
            let children = try await list(url, options: ListOptions(showHidden: true))
            for child in children {
                try await delete(child.url)
            }
            _ = try await run(
                url: commandURL,
                extra: ["quote = \"RMD \(escapeConfig(url.path))\""]
            )
        } else {
            _ = try await run(
                url: commandURL,
                extra: ["quote = \"DELE \(escapeConfig(url.path))\""]
            )
        }
    }

    public func trash(_ url: URL) async throws -> URL {
        throw FileProviderError.ioFailure(
            url,
            underlying: "Remote items are deleted permanently; the Trash is local-only"
        )
    }

    public func isDirectory(_ url: URL) async -> Bool {
        if let metadata = try? await metadata(for: url) {
            return metadata.isDirectory
        }
        return false
    }

    public func download(_ remote: URL, to local: URL) async throws {
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try await run(
            url: ftpURL(remote, directory: false),
            extra: ["output = \"\(escapeConfig(local.path))\""]
        )
    }

    public func upload(_ local: URL, to remote: URL) async throws {
        _ = try await run(
            url: ftpURL(remote, directory: false),
            extra: [
                "upload-file = \"\(escapeConfig(local.path))\"",
                "ftp-create-dirs"
            ]
        )
    }

    // MARK: Transport

    private var commandURL: String {
        ftpURL(URL(fileURLWithPath: "/"), directory: true)
    }

    private func ftpURL(_ url: URL, directory: Bool) -> String {
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = connection.host
        components.port = connection.port
        var path = url.path
        if path.isEmpty { path = "/" }
        if directory, !path.hasSuffix("/") { path += "/" }
        components.percentEncodedPath = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? path
        return components.url?.absoluteString ?? ""
    }

    private func run(url: String, extra: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.runSync(url: url, extra: extra)
        }.value
    }

    private func runSync(url: String, extra: [String]) throws -> String {
        var config = [
            "silent",
            "show-error",
            "max-time = 60",
            "url = \"\(escapeConfig(url))\""
        ]
        if !connection.username.isEmpty {
            let credentials = "\(connection.username):\(connection.password)"
            config.append("user = \"\(escapeConfig(credentials))\"")
        }
        if connection.proto.isTLS {
            config.append("ssl-reqd")
        }
        config.append(contentsOf: extra)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--config", "-"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw FileProviderError.ioFailure(connection.rootURL, underlying: error.localizedDescription)
        }

        input.fileHandleForWriting.write(Data((config.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        if process.terminationStatus != 0 {
            throw FileProviderError.ioFailure(connection.rootURL, underlying: text)
        }
        return text
    }

    private func escapeConfig(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

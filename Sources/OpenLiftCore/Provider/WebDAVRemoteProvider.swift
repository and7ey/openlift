import Foundation
import UniformTypeIdentifiers

/// Parses a WebDAV `PROPFIND` multistatus response into file items.
public struct WebDAVListingParser: Sendable {
    public init() {}

    public func items(from data: Data, base: URL, showHidden: Bool) -> [FileItem] {
        let parser = MultistatusParser()
        guard parser.parse(data) else { return [] }

        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return parser.resources.compactMap { resource -> FileItem? in
            guard let url = URL(string: resource.href, relativeTo: base)?.absoluteURL else { return nil }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == basePath { return nil }

            let rawName = resource.displayName.isEmpty
                ? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                : resource.displayName
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if !showHidden, name.hasPrefix(".") { return nil }

            let contentType = resource.contentType.flatMap {
                UTType(mimeType: $0)?.identifier
            }
            return FileItem(
                url: url,
                name: name,
                isDirectory: resource.isCollection,
                isSymlink: false,
                isHidden: name.hasPrefix("."),
                isPackage: false,
                isAlias: false,
                size: resource.isCollection ? nil : resource.contentLength,
                modified: resource.modified,
                created: nil,
                contentTypeIdentifier: resource.isCollection ? UTType.folder.identifier : contentType,
                permissions: nil,
                owner: nil
            )
        }
    }

    private final class MultistatusParser: NSObject, XMLParserDelegate {
        struct Resource {
            var href = ""
            var displayName = ""
            var isCollection = false
            var contentLength: Int64?
            var contentType: String?
            var modified: Date?
        }

        private(set) var resources: [Resource] = []
        private var current: Resource?
        private var text = ""

        private static let modifiedFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        func parse(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = true
            return parser.parse()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            switch elementName.lowercased() {
            case "response":
                current = Resource()
            case "collection":
                current?.isCollection = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName.lowercased() {
            case "href":
                current?.href = value
            case "displayname":
                current?.displayName = value
            case "getcontentlength":
                current?.contentLength = Int64(value)
            case "getcontenttype":
                current?.contentType = value
            case "getlastmodified":
                current?.modified = Self.modifiedFormatter.date(from: value)
            case "response":
                if let current { resources.append(current) }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}

/// WebDAV/WebDAVS provider using URLSession: PROPFIND for listings and
/// standard HTTP verbs for mutations and transfers.
public struct WebDAVRemoteProvider: FileProvider, RemoteFileTransferring {
    public let identifier: String
    public let displayName: String

    private let connection: RemoteConnection
    private let parser = WebDAVListingParser()

    public init(connection: RemoteConnection) {
        self.connection = connection
        identifier = "remote:\(connection.proto.rawValue)"
        displayName = connection.displayName
    }

    public func list(_ directory: URL, options: ListOptions) async throws -> [FileItem] {
        let url = directoryURL(directory)
        var request = makeRequest(method: "PROPFIND", url: url)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await send(request, context: directory)
        guard response.statusCode == 207 else {
            throw FileProviderError.ioFailure(directory, underlying: "WebDAV returned HTTP \(response.statusCode)")
        }
        return parser.items(from: data, base: url, showHidden: options.showHidden)
    }

    public func metadata(for url: URL) async throws -> FileItem {
        var request = makeRequest(method: "PROPFIND", url: url)
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await send(request, context: url)
        guard response.statusCode == 207 else {
            throw FileProviderError.ioFailure(url, underlying: "WebDAV returned HTTP \(response.statusCode)")
        }
        let items = parser.items(from: data, base: url, showHidden: true)
        guard let item = items.first else {
            throw FileProviderError.notFound(url)
        }
        return item
    }

    public func createDirectory(at url: URL) async throws {
        let request = makeRequest(method: "MKCOL", url: url)
        _ = try await send(request, context: url, accepted: [200, 201, 204])
    }

    public func move(_ source: URL, to destination: URL) async throws {
        var request = makeRequest(method: "MOVE", url: source)
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        _ = try await send(request, context: source, accepted: [200, 201, 204])
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        var request = makeRequest(method: "COPY", url: source)
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        request.setValue("infinity", forHTTPHeaderField: "Depth")
        _ = try await send(request, context: source, accepted: [200, 201, 204])
    }

    public func delete(_ url: URL) async throws {
        let request = makeRequest(method: "DELETE", url: url)
        _ = try await send(request, context: url, accepted: [200, 204])
    }

    public func trash(_ url: URL) async throws -> URL {
        throw FileProviderError.ioFailure(
            url,
            underlying: "Remote items are deleted permanently; the Trash is local-only"
        )
    }

    public func isDirectory(_ url: URL) async -> Bool {
        (try? await metadata(for: url))?.isDirectory ?? false
    }

    // MARK: - Transfers

    public func download(_ remote: URL, to local: URL) async throws {
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let request = makeRequest(method: "GET", url: remote)
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw FileProviderError.ioFailure(remote, underlying: "WebDAV returned HTTP \(code)")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: local.path) {
            try manager.removeItem(at: local)
        }
        try manager.moveItem(at: temp, to: local)
    }

    public func upload(_ local: URL, to remote: URL) async throws {
        let data = try Data(contentsOf: local)
        var request = makeRequest(method: "PUT", url: remote)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request, context: remote, accepted: [200, 201, 204])
    }

    // MARK: - HTTP

    private func makeRequest(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if !connection.username.isEmpty {
            let token = Data("\(connection.username):\(connection.password)".utf8)
                .base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(
        _ request: URLRequest,
        context: URL,
        accepted: Set<Int> = [200, 201, 204, 207]
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FileProviderError.ioFailure(context, underlying: "WebDAV returned a non-HTTP response")
        }
        guard accepted.contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = body.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(body.prefix(300))"
            throw FileProviderError.ioFailure(context, underlying: detail)
        }
        return (data, http)
    }

    private func directoryURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.path.hasSuffix("/") == false {
            components?.path += "/"
        }
        return components?.url ?? url
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:displayname/>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getlastmodified/>
        <D:getcontenttype/>
      </D:prop>
    </D:propfind>
    """
}

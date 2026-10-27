import Foundation

/// Immutable snapshot of a filesystem entry.
///
/// `FileItem` is a value type on purpose: the browser can hand it across
/// concurrency domains (listing happens off the main thread) without sharing
/// mutable state. The tree/list wiring lives in `BrowserNode`.
public struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let isPackage: Bool
    public let isAlias: Bool
    /// Logical size in bytes. `nil` for entries the provider could not stat.
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    public let contentTypeIdentifier: String?
    public let permissions: String?
    public let owner: String?

    public var id: URL { url }

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        isHidden: Bool = false,
        isPackage: Bool = false,
        isAlias: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        created: Date? = nil,
        contentTypeIdentifier: String? = nil,
        permissions: String? = nil,
        owner: String? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.isAlias = isAlias
        self.size = size
        self.modified = modified
        self.created = created
        self.contentTypeIdentifier = contentTypeIdentifier
        self.permissions = permissions
        self.owner = owner
    }

    /// A directory the browser may descend into. Packages (`.app`, bundles)
    /// are treated as files in the list, matching Finder/ForkLift defaults.
    public var isBrowsableDirectory: Bool { isDirectory && !isPackage }

    /// Human readable kind, e.g. `Folder`, `PNG image`, `Plain text`.
    public var kind: String {
        if isDirectory {
            return isPackage ? "Package" : "Folder"
        }
        if isSymlink { return "Alias" }
        guard let id = contentTypeIdentifier else { return "Document" }
        return FileItem.kindLabels[id] ?? id
    }

    private static let kindLabels: [String: String] = [
        "public.png": "PNG image",
        "public.jpeg": "JPEG image",
        "public.tiff": "TIFF image",
        "public.heic": "HEIC image",
        "com.compuserve.gif": "GIF image",
        "public.svg-image": "SVG image",
        "public.plain-text": "Plain text",
        "public.rtf": "Rich text",
        "public.html": "HTML document",
        "public.json": "JSON document",
        "public.xml": "XML document",
        "public.source-code": "Source code",
        "net.daringfireball.markdown": "Markdown",
        "public.c-source": "Source code",
        "public.objective-c-source": "Source code",
        "public.swift-source": "Swift source",
        "public.shell-script": "Shell script",
        "com.apple.property-list": "Property list",
        "public.movie": "Movie",
        "public.audio": "Audio",
        "com.adobe.pdf": "PDF document",
        "public.zip-archive": "ZIP archive",
        "com.apple.bundle": "Bundle",
        "public.executable": "Unix executable",
        "public.unix-executable": "Unix executable",
        "com.apple.application-bundle": "Application",
        "public.folder": "Folder"
    ]
}

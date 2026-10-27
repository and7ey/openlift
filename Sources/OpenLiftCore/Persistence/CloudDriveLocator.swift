import Foundation

/// A cloud drive made available on disk by its vendor's sync client.
public struct CloudDrive: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let symbol: String

    public init(name: String, url: URL, symbol: String) {
        self.name = name
        self.url = url
        self.symbol = symbol
    }
}

/// Finds cloud folders synced by installed desktop clients.
///
/// OpenLift does not reimplement Dropbox/Drive/OneDrive protocols: it surfaces
/// the folders those clients already keep in sync, next to iCloud Drive. That
/// keeps sign-in, conflict handling and offline state with the vendor.
public struct CloudDriveLocator: Sendable {
    public init() {}

    public func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        cloudStorage: URL? = nil
    ) -> [CloudDrive] {
        let manager = FileManager.default
        var drives: [CloudDrive] = []
        var seen: Set<String> = []

        func add(_ name: String, _ url: URL, _ symbol: String) {
            guard manager.fileExists(atPath: url.path) else { return }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { return }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            drives.append(CloudDrive(name: name, url: url.standardizedFileURL, symbol: symbol))
        }

        // iCloud Drive is always represented by this fixed container path.
        add(
            "iCloud Drive",
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true),
            "icloud"
        )

        // Older clients sync into the home folder; newer ones use CloudStorage.
        add("Dropbox", home.appendingPathComponent("Dropbox", isDirectory: true), "shippingbox")
        add("Google Drive", home.appendingPathComponent("Google Drive", isDirectory: true), "triangle")
        add("OneDrive", home.appendingPathComponent("OneDrive", isDirectory: true), "cloud")
        add("Box", home.appendingPathComponent("Box", isDirectory: true), "archivebox")

        let storageRoot = cloudStorage
            ?? home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let children = try? manager.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in children {
                let folder = url.lastPathComponent
                let (base, detail, symbol): (String, String?, String)
                if folder.hasPrefix("GoogleDrive-") {
                    base = "Google Drive"
                    detail = String(folder.dropFirst("GoogleDrive-".count))
                    symbol = "triangle"
                } else if folder.hasPrefix("OneDrive-") {
                    base = "OneDrive"
                    detail = String(folder.dropFirst("OneDrive-".count))
                    symbol = "cloud"
                } else if folder.hasPrefix("Box-") {
                    base = "Box"
                    detail = String(folder.dropFirst("Box-".count))
                    symbol = "archivebox"
                } else if folder == "Dropbox" {
                    base = "Dropbox"
                    detail = nil
                    symbol = "shippingbox"
                } else {
                    base = folder
                    detail = nil
                    symbol = "cloud"
                }
                let name = detail.flatMap { value -> String? in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? nil : "\(base) (\(trimmed))"
                } ?? base
                add(name, url, symbol)
            }
        }

        return drives.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

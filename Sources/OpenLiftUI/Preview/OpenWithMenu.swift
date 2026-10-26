import AppKit

/// Shared helpers for the "Open With" menus (menu bar and context menu).
@MainActor
public enum OpenWithMenu {
    /// Applications that can open `url`, sorted by display name.
    public static func applications(for url: URL) -> [URL] {
        NSWorkspace.shared
            .urlsForApplications(toOpen: url)
            .filter { $0.pathExtension == "app" }
            .sorted {
                displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
            }
    }

    public static func displayName(for application: URL) -> String {
        application.deletingPathExtension().lastPathComponent
    }

    /// Opens one file (or folder) with an explicit application.
    public static func open(_ url: URL, with application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
    }
}

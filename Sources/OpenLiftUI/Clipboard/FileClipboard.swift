import AppKit

/// File-level clipboard shared by every pane.
///
/// Copy and cut put real file URLs on the general pasteboard, so Finder and
/// other apps can consume them. A private marker records that the last write
/// was a cut; paste then moves instead of copying and the marker is consumed
/// once the move succeeds.
@MainActor
public final class FileClipboard {
    public enum Mode: Sendable {
        case copy
        case cut
    }

    public static let shared = FileClipboard()

    private static let cutType = NSPasteboard.PasteboardType("dev.openlift.clipboard.cut")

    private init() {}

    /// File URLs currently on the pasteboard.
    public var urls: [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return objects ?? []
    }

    /// True when the last write came from `cut` and has not been pasted yet.
    public var isCut: Bool {
        NSPasteboard.general.types?.contains(Self.cutType) ?? false
    }

    public func write(_ urls: [URL], mode: Mode) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        if mode == .cut {
            pasteboard.setString("cut", forType: Self.cutType)
        }
    }

    /// Drops a cut once it has been moved so a second paste cannot move ghosts.
    public func consumeCut() {
        guard isCut else { return }
        NSPasteboard.general.clearContents()
    }
}

import AppKit
import QuickLookUI

/// Owns the shared Quick Look panel for the browser.
///
/// The panel is a system window: it previews the selected URLs and lets the
/// user step through them with the arrow keys. `present(_:)` also acts as a
/// toggle, so pressing Space twice closes the preview.
public final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor public static let shared = QuickLookController()

    private var urls: [URL] = []

    private override init() {
        super.init()
    }

    @MainActor public func present(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, urls == self.urls {
            panel.orderOut(nil)
            return
        }

        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}

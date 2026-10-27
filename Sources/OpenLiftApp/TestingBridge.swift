#if DEBUG
import AppKit

/// Dev-only command channel for UI tests.
///
/// Enabled with `OPENLIFT_TESTING=1`. Tests post a distributed notification
/// (`dev.openlift.test`) with a command and arguments, which lets them drive
/// the app without activating it, moving the cursor or using the menu bar.
/// A virtual display can host the windows, so a person keeps working on the
/// main display while tests run.
@MainActor
final class TestingBridge: NSObject {
    private weak var controller: MainWindowController?

    private static let allowedSelectors: Set<String> = [
        "openSelection:",
        "quickLook:",
        "showInfo:",
        "newFolder:",
        "paste:",
        "compressSelection:",
        "moveToTrash:",
        "copyToOtherPane:",
        "moveToOtherPane:",
        "showAdvancedSearch:",
        "goHome:",
        "refresh:",
        "searchHereFromMenu:",
        "searchRecursivelyFromMenu:",
        "searchContentsFromMenu:",
        "filterFromMenu:"
    ]

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handle(_:)),
            name: Notification.Name("dev.openlift.test"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handle(_ notification: Notification) {
        guard let info = notification.userInfo,
              let command = info["command"] as? String,
              let controller else { return }

        switch command {
        case "invoke":
            guard let name = info["selector"] as? String,
                  Self.allowedSelectors.contains(name) else { return }
            _ = controller.testInvoke(name)

        case "navigate":
            guard let path = info["path"] as? String else { return }
            controller.testNavigate(to: URL(fileURLWithPath: path, isDirectory: true))

        case "newTab":
            guard let path = info["path"] as? String else { return }
            controller.testNewTab(at: URL(fileURLWithPath: path, isDirectory: true))

        case "search":
            guard let path = info["root"] as? String else { return }
            controller.testOpenAdvancedSearch(
                root: URL(fileURLWithPath: path, isDirectory: true),
                recursive: info["recursive"] as? Bool ?? true,
                focusContent: info["focusContent"] as? Bool ?? false
            )

        case "selectTab":
            guard let raw = info["index"] as? String, let index = Int(raw) else { return }
            controller.testSelectTab(index)

        default:
            break
        }
    }
}

#endif

#if DEBUG
import AppKit
import OpenLiftCore

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
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// Plain strings extracted from the notification before hopping onto the
    /// main actor; distributed notifications may carry arbitrary property-list
    /// values, so everything else is ignored.
    private struct Payload: Sendable {
        var command: String
        var values: [String: String]
        var recursive: Bool
        var focusContent: Bool

        func value(_ key: String) -> String? {
            let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
    }

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
        "filterFromMenu:",
        "showShortcuts:",
        "showSettings:",
        "batchRenameSelection:",
        "undo:",
        "redo:",
        "connectToServer:",
        "downloadToOtherPane:",
        "uploadToOtherPane:",
        "renameSelection:",
        "compareFolders:",
        "extractToOtherPane:",
        "refreshGitStatus:",
        "stageGitSelection:",
        "unstageGitSelection:",
        "commitGitChanges:",
        "discardGitChanges:"
    ]

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
        // A block observer keeps the entry point out of the Objective-C
        // selector machinery and makes the main-queue hop explicit.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.openlift.test"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            var values: [String: String] = [:]
            for (key, value) in info ?? [:] {
                if let key = key as? String, let value = value as? String {
                    values[key] = value
                }
            }
            let payload = Payload(
                command: (values["command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                values: values,
                recursive: info?["recursive"] as? Bool ?? true,
                focusContent: info?["focusContent"] as? Bool ?? false
            )
            MainActor.assumeIsolated {
                self?.handle(payload)
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func handle(_ payload: Payload) {
        guard !payload.command.isEmpty, let controller else { return }

        switch payload.command {
        case "invoke":
            guard let name = payload.value("selector"),
                  Self.allowedSelectors.contains(name) else { return }
            _ = controller.testInvoke(name)

        case "navigate":
            guard let path = payload.value("path") else { return }
            controller.testNavigate(to: URL(fileURLWithPath: path, isDirectory: true))

        case "theme":
            guard let id = payload.value("id") else { return }
            controller.testSetTheme(id)

        case "newTab":
            guard let path = payload.value("path") else { return }
            controller.testNewTab(at: URL(fileURLWithPath: path, isDirectory: true))

        case "search":
            guard let path = payload.value("root") else { return }
            controller.testOpenAdvancedSearch(
                root: URL(fileURLWithPath: path, isDirectory: true),
                recursive: payload.recursive,
                focusContent: payload.focusContent
            )

        case "selectTab":
            guard let raw = payload.value("index"), let index = Int(raw) else { return }
            controller.testSelectTab(index)

        case "remote":
            guard let protoRaw = payload.value("proto"),
                  let proto = RemoteProtocol(rawValue: protoRaw),
                  let host = payload.value("host") else { return }
            let port = payload.value("port").flatMap(Int.init) ?? proto.defaultPort
            let connection = RemoteConnection(
                proto: proto,
                host: host,
                port: port,
                username: payload.value("user") ?? "",
                password: payload.value("password") ?? "",
                identityFile: payload.value("key"),
                path: payload.value("path") ?? "/"
            )
            controller.testOpenRemote(connection)

        default:
            break
        }
    }
}

#endif

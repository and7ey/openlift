import Foundation
import CoreGraphics

/// One browser pane's restorable state.
public struct PaneState: Codable, Equatable, Sendable {
    public var path: String
    public var backHistory: [String]
    public var forwardHistory: [String]
    public var settings: ViewSettings

    public init(
        path: String,
        backHistory: [String] = [],
        forwardHistory: [String] = [],
        settings: ViewSettings = .default
    ) {
        self.path = path
        self.backHistory = backHistory
        self.forwardHistory = forwardHistory
        self.settings = settings
    }
}

/// Saved layout of a browser window.
public struct WindowState: Codable, Equatable, Sendable {
    public var frame: CGRect
    public var sidebarWidth: Double
    public var splitRatio: Double
    public var singlePane: Bool
    public var horizontalPanes: Bool
    public var left: PaneState
    public var right: PaneState
    public var activePane: Int
    /// Tabs per pane. `nil` in states written by older builds.
    public var leftTabs: [PaneState]?
    public var rightTabs: [PaneState]?
    public var leftActiveTab: Int?
    public var rightActiveTab: Int?

    public init(
        frame: CGRect,
        sidebarWidth: Double = 220,
        splitRatio: Double = 0.5,
        singlePane: Bool = false,
        horizontalPanes: Bool = false,
        left: PaneState,
        right: PaneState,
        activePane: Int = 0,
        leftTabs: [PaneState]? = nil,
        rightTabs: [PaneState]? = nil,
        leftActiveTab: Int? = nil,
        rightActiveTab: Int? = nil
    ) {
        self.frame = frame
        self.sidebarWidth = sidebarWidth
        self.splitRatio = splitRatio
        self.singlePane = singlePane
        self.horizontalPanes = horizontalPanes
        self.left = left
        self.right = right
        self.activePane = activePane
        self.leftTabs = leftTabs
        self.rightTabs = rightTabs
        self.leftActiveTab = leftActiveTab
        self.rightActiveTab = rightActiveTab
    }

    public static func makeDefault(home: String = NSHomeDirectory()) -> WindowState {
        WindowState(
            frame: CGRect(x: 0, y: 0, width: 1100, height: 700),
            left: PaneState(path: home),
            right: PaneState(path: home)
        )
    }
}

/// Persists window layout as JSON.
public final class WindowStateStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.openlift.window-state")

    public init(fileURL: URL = AppPaths.windowStateFile) {
        self.fileURL = fileURL
    }

    public func load() -> WindowState {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let state = try? JSONDecoder().decode(WindowState.self, from: data) else {
                return .makeDefault()
            }
            return state
        }
    }

    public func save(_ state: WindowState) {
        queue.sync {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(state).write(to: fileURL, options: .atomic)
            } catch {
                NSLog("OpenLift: failed to save window state — \(error.localizedDescription)")
            }
        }
    }
}

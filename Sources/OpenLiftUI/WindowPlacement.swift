import AppKit

/// Sends new windows to the test virtual display when it is present.
///
/// The app is normally used on the built-in display; during automated UI tests
/// a virtual display named “OpenLift Test Display” hosts the windows so the
/// person at the Mac keeps an unobstructed desktop. Outside that mode this is
/// just `NSWindow.center()`.
@MainActor
public enum TestWindowPlacement {
    public static var isActive: Bool {
        ProcessInfo.processInfo.environment["OPENLIFT_TESTING"] == "1"
    }

    public static func place(_ window: NSWindow, offset: CGFloat = 0) {
        guard isActive,
              let screen = NSScreen.screens.first(where: {
                  $0.localizedName.contains("OpenLift Test")
              }) else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.minX + 40 + offset,
            y: visible.maxY - window.frame.height - 40 - offset
        )
        window.setFrameOrigin(origin)
    }

    /// Keeps the restored main window on the test display during test runs.
    public static func placeMainWindow(_ window: NSWindow) {
        guard isActive,
              let screen = NSScreen.screens.first(where: {
                  $0.localizedName.contains("OpenLift Test")
              }) else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.maxY - window.frame.height - 40))
    }
}

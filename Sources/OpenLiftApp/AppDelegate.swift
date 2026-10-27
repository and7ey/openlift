import AppKit

/// Application lifecycle.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    #if DEBUG
    private var testingBridge: TestingBridge?
    #endif

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let isTesting = ProcessInfo.processInfo.environment["OPENLIFT_TESTING"] == "1"
        // Test runs use an accessory app on a virtual display: no Dock icon,
        // no menu bar and, crucially, no activation stealing focus from the
        // person using the Mac.
        NSApp.setActivationPolicy(isTesting ? .accessory : .regular)
        #else
        NSApp.setActivationPolicy(.regular)
        #endif

        let controller = MainWindowController()
        mainWindowController = controller

        NSApp.mainMenu = MenuBuilder.build(target: controller)
        controller.applyShortcuts()

        controller.showWindow(nil)

        #if DEBUG
        if isTesting {
            controller.window?.orderFront(nil)
            testingBridge = TestingBridge(controller: controller)
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        #else
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveWindowState()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }
}

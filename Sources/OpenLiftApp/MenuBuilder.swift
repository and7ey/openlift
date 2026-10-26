import AppKit
import OpenLiftCore

/// Builds the application menu bar.
///
/// The menu mirrors the command set the browser exposes; every item routes to
/// the same selectors the toolbar and keyboard use.
@MainActor
public enum MenuBuilder {

    public static func build(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(fileMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(goMenuItem(target: target))
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())

        return mainMenu
    }

    // MARK: - Menus

    private static func applicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "OpenLift")

        menu.addItem(withTitle: "About OpenLift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide OpenLift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenLift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func fileMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        menu.addItem(makeItem("New Folder", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift], target))
        menu.addItem(makeItem("Rename…", #selector(MainWindowController.renameSelection(_:)), "\r", [], target))
        menu.addItem(makeItem("Duplicate", #selector(MainWindowController.duplicateSelection(_:)), "d", [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open", #selector(MainWindowController.openSelection(_:)), "o", [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Copy to Other Pane", #selector(MainWindowController.copyToOtherPane(_:)), "c", [.command, .control], target))
        menu.addItem(makeItem("Move to Other Pane", #selector(MainWindowController.moveToOtherPane(_:)), "m", [.command, .control], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Move to Trash", #selector(MainWindowController.moveToTrash(_:)), String(UnicodeScalar(NSBackspaceCharacter)!), [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift], target))
        menu.addItem(makeItem("Open in Terminal", #selector(MainWindowController.openInTerminal(_:)), "t", [.command, .control], target))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    private static func viewMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        menu.addItem(makeItem("as List", #selector(MainWindowController.setViewMode(_:)), "1", [.command], target, represented: ViewSettings.Mode.list.rawValue))
        menu.addItem(makeItem("as Icons", #selector(MainWindowController.setViewMode(_:)), "2", [.command], target, represented: ViewSettings.Mode.icon.rawValue))
        menu.addItem(.separator())

        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        for key in SortKey.allCases {
            sortMenu.addItem(makeItem(key.title, #selector(MainWindowController.sortBy(_:)), "", [], target, represented: key.rawValue))
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift], target))
        menu.addItem(makeItem("Refresh", #selector(MainWindowController.refresh(_:)), "r", [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Show Sidebar", #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .control], target))
        menu.addItem(makeItem("Single Pane", #selector(MainWindowController.toggleSinglePane(_:)), "\\", [.command], target))
        menu.addItem(makeItem("Swap Panes", #selector(MainWindowController.swapPanes(_:)), "s", [.command, .shift], target))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        item.submenu = menu
        return item
    }

    private static func goMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Go")
        menu.addItem(makeItem("Back", #selector(MainWindowController.goBack(_:)), "[", [.command], target))
        menu.addItem(makeItem("Forward", #selector(MainWindowController.goForward(_:)), "]", [.command], target))
        menu.addItem(makeItem("Enclosing Folder", #selector(MainWindowController.goUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command], target))
        menu.addItem(makeItem("Home", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift], target))
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "OpenLift Help", action: nil, keyEquivalent: "?")
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    // MARK: - Helpers

    private static func makeItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags,
        _ target: AnyObject,
        represented: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.representedObject = represented
        return item
    }
}

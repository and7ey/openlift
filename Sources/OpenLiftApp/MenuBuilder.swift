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

        mainMenu.addItem(applicationMenuItem(target: target))
        mainMenu.addItem(fileMenuItem(target: target))
        mainMenu.addItem(editMenuItem(target: target))
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(goMenuItem(target: target))
        mainMenu.addItem(windowMenuItem(target: target))
        mainMenu.addItem(helpMenuItem())

        return mainMenu
    }

    // MARK: - Menus

    private static func applicationMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "OpenLift")

        menu.addItem(withTitle: "About OpenLift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(MainWindowController.showSettings(_:)), ",", [.command], target))
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

        menu.addItem(makeItem("New Tab", #selector(MainWindowController.newTab(_:)), "t", [.command], target))
        menu.addItem(makeItem("Close Tab", #selector(MainWindowController.closeTab(_:)), "w", [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("New Folder", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift], target))
        menu.addItem(makeItem("Rename…", #selector(MainWindowController.renameSelection(_:)), "\r", [], target))
        menu.addItem(makeItem("Duplicate", #selector(MainWindowController.duplicateSelection(_:)), "d", [.command], target))
        menu.addItem(makeItem("Compress", #selector(MainWindowController.compressSelection(_:)), "", [], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open", #selector(MainWindowController.openSelection(_:)), "o", [.command], target))
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let openWithMenu = NSMenu(title: "Open With")
        openWithMenu.delegate = target as? NSMenuDelegate
        openWithItem.submenu = openWithMenu
        menu.addItem(openWithItem)
        menu.addItem(makeItem("Get Info", #selector(MainWindowController.showInfo(_:)), "i", [.command], target))
        menu.addItem(makeItem("Quick Look", #selector(MainWindowController.quickLook(_:)), "y", [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Copy to Other Pane", #selector(MainWindowController.copyToOtherPane(_:)), "c", [.command, .control], target))
        menu.addItem(makeItem("Move to Other Pane", #selector(MainWindowController.moveToOtherPane(_:)), "m", [.command, .control], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Move to Trash", #selector(MainWindowController.moveToTrash(_:)), String(UnicodeScalar(NSBackspaceCharacter)!), [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift], target))
        menu.addItem(makeItem("Open in Terminal", #selector(MainWindowController.openInTerminal(_:)), "t", [.command, .control], target))

        item.submenu = menu
        return item
    }

    private static func editMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(makeItem("Undo", #selector(MainWindowController.undo(_:)), "z", [.command], target))
        let redo = makeItem("Redo", #selector(MainWindowController.redo(_:)), "z", [.command, .shift], target)
        menu.addItem(redo)
        menu.addItem(.separator())

        // File operations are targeted at the window controller so they always
        // act on the active pane, whichever view holds focus. Text editing only
        // happens inside modal sheets, where the menu bar is disabled.
        menu.addItem(makeItem("Cut", #selector(MainWindowController.cut(_:)), "x", [.command], target))
        menu.addItem(makeItem("Copy", #selector(MainWindowController.copy(_:)), "c", [.command], target))
        menu.addItem(makeItem("Paste", #selector(MainWindowController.paste(_:)), "v", [.command], target))
        menu.addItem(.separator())
        menu.addItem(makeItem("Find in Folder…", #selector(MainWindowController.find(_:)), "f", [.command], target))
        menu.addItem(makeItem("Advanced Search…", #selector(MainWindowController.showAdvancedSearch(_:)), "f", [.command, .shift], target))
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

        let groupItem = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu(title: "Group by")
        for key in GroupKey.allCases {
            groupMenu.addItem(makeItem(key.title, #selector(MainWindowController.groupBy(_:)), "", [], target, represented: key.rawValue))
        }
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

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
        menu.addItem(.separator())
        menu.addItem(makeItem("Go to Folder…", #selector(MainWindowController.goToFolder(_:)), "g", [.command, .shift], target))
        item.submenu = menu
        return item
    }

    private static func windowMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(makeItem("Activity", #selector(MainWindowController.showActivity(_:)), "a", [.command, .option], target))
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(makeItem("Show Next Tab", #selector(MainWindowController.showNextTab(_:)), "\t", [.control], target))
        menu.addItem(makeItem("Show Previous Tab", #selector(MainWindowController.showPreviousTab(_:)), "\t", [.control, .shift], target))
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

import AppKit
import OpenLiftApp

// OpenLift is a plain AppKit application. A top-level bootstrap keeps the
// binary runnable both from `swift run` and from an assembled .app bundle.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

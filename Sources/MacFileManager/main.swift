import AppKit

let application = NSApplication.shared
let appDelegate = FileManagerAppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()

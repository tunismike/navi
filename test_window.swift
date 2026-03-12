import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 800, height: 600)
        let rect = NSRect(x: screenSize.width/2 - 50, y: screenSize.height/2 - 50, width: 100, height: 100)
        
        window = NSWindow(contentRect: rect,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        
        let view = NSView(frame: rect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.blue.withAlphaComponent(0.5).cgColor
        view.layer?.cornerRadius = 50
        window.contentView = view
        
        // Move around
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 2.0
            window.animator().setFrame(NSRect(x: 100, y: 100, width: 100, height: 100), display: true)
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

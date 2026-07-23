import AppKit
import WebKit

final class HelpWindow {
    static let shared = HelpWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Stick-It Help"
            w.isReleasedWhenClosed = false
            w.center()
            let webView = WKWebView(frame: .zero)
            if let url = Bundle.main.url(forResource: "help", withExtension: "html") {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            w.contentView = webView
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

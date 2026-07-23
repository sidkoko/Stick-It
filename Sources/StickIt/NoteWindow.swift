import AppKit
import WebKit

/// Borderless windows refuse key status by default — a note has to accept typing.
final class PaperWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class NoteWindowController: NSWindowController, NSWindowDelegate, WKScriptMessageHandler {
    static let barHeight: CGFloat = 30   // must match #bar { height } in editor.html
    var note: Note
    private var webView: WKWebView!
    private var expandedHeight: CGFloat
    private var loaded = false
    private var dragStart: NSPoint?
    private var resizeStart: NSRect?
    private var peelStart: NSPoint?
    private var spawnedID: String?
    private var frameSaveWork: DispatchWorkItem?

    init(note: Note) {
        self.note = note
        self.expandedHeight = note.h

        let window = PaperWindow(
            contentRect: NSRect(x: note.x, y: note.y, width: note.w,
                                height: note.collapsed ? Self.barHeight : note.h),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        applyPin()
        clampToScreen()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let config = WKWebViewConfiguration()
        for name in ["save", "peel", "ui", "win"] {
            config.userContentController.add(self, name: name)
        }
        webView = WKWebView(frame: content.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = navDelegate
        content.addSubview(webView)

        if let url = Bundle.main.url(forResource: "editor", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private lazy var navDelegate = NavDelegate { [weak self] in
        guard let self else { return }
        self.loaded = true
        self.pushContent()
        self.window?.makeFirstResponder(self.webView)
    }

    private func pushContent() {
        guard loaded else { return }
        let payload: [String: Any] = [
            "html": note.html,
            "hex": (NoteColor(rawValue: note.color) ?? .yellow).hex,
            "paper": note.paper ?? "plain",
            "drawing": note.drawing ?? "",
            "name": note.name ?? "",
            "pinned": note.pinned,
            "collapsed": note.collapsed,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("setNote(\(json))")
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        switch message.name {
        case "save": handleSave(body)
        case "peel": handlePeel(body)
        case "ui":   handleUI(body)
        case "win":  handleWin(body)
        default: break
        }
    }

    private func handleSave(_ body: [String: Any]) {
        note.html = body["html"] as? String ?? note.html
        note.text = body["text"] as? String ?? note.text
        note.md = body["md"] as? String ?? note.md
        if let d = body["drawing"] as? String { note.drawing = d.isEmpty ? nil : d }
        note.updatedAt = Date()
        NoteStore.shared.save(note)
    }

    private func handleUI(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }
        switch action {
        case "close":
            note.open = false
            NoteStore.shared.save(note)
            close()
        case "collapse":
            toggleCollapsed()
        case "pin":
            note.pinned.toggle()
            applyPin()
            NoteStore.shared.save(note)
        case "rename":
            let value = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            note.name = value.isEmpty ? nil : value
            note.updatedAt = Date()
            NoteStore.shared.save(note)
        case "colorMenu":
            popUp(colorMenu(), body)
        case "shareMenu":
            popUp(shareMenu(), body)
        case "moreMenu":
            popUp(moreMenu(), body)
        default: break
        }
    }

    /// Shows an NSMenu just below the HTML button that asked for it.
    /// WKWebView is a flipped view (top-left origin, y grows downward) — same as the
    /// CSS pixel coordinates the JS side sends, so no axis conversion is needed.
    private func popUp(_ menu: NSMenu, _ body: [String: Any]) {
        let x = body["x"] as? Double ?? 0
        let y = body["y"] as? Double ?? 0
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: webView)
    }

    private func handleWin(_ body: [String: Any]) {
        guard let window, let phase = body["phase"] as? String else { return }
        switch phase {
        case "dragStart":
            dragStart = window.frame.origin
        case "drag":
            guard let origin = dragStart,
                  let dx = body["dx"] as? Double, let dy = body["dy"] as? Double else { return }
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y - dy))
        case "resizeStart":
            resizeStart = window.frame
        case "resize":
            guard let start = resizeStart,
                  let dx = body["dx"] as? Double, let dy = body["dy"] as? Double,
                  let edge = body["edge"] as? String else { return }
            var f = start
            if edge.contains("e") { f.size.width = max(320, start.width + dx) }
            if edge.contains("w") {
                let w = max(320, start.width - dx)
                f.origin.x = start.maxX - w
                f.size.width = w
            }
            if edge.contains("s") {
                let h = max(200, start.height + dy)
                f.origin.y = start.maxY - h
                f.size.height = h
            }
            if edge.contains("n") {
                f.size.height = max(200, start.height - dy)
            }
            window.setFrame(f, display: true)
        case "end":
            dragStart = nil
            resizeStart = nil
            window.invalidateShadow()
            saveFrame()
        default: break
        }
    }

    // MARK: peel a page off the pad

    private func handlePeel(_ body: [String: Any]) {
        guard let window, let phase = body["phase"] as? String else { return }
        switch phase {
        case "reveal":
            // far enough into the peel that the page underneath should exist
            guard spawnedID == nil else { return }
            spawnedID = NoteManager.shared.spawnNoteUnder(current: self)
        case "detach":
            peelStart = window.frame.origin
            spawnedID = nil            // the new page stays; this one is now loose
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        case "move":
            guard let origin = peelStart,
                  let dx = body["dx"] as? Double, let dy = body["dy"] as? Double else { return }
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y - dy))
        case "cancel":
            // peel abandoned — take back the blank page we revealed
            if let id = spawnedID {
                NoteManager.shared.discardIfUntouched(id)
                spawnedID = nil
            }
        case "end":
            peelStart = nil
            window.invalidateShadow()
            saveFrame()
        default: break
        }
    }

    // MARK: menus

    private func colorMenu() -> NSMenu {
        let menu = NSMenu()
        for c in NoteColor.allCases {
            let item = NSMenuItem(title: c.rawValue.capitalized, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.image = swatch(c.nsColor)
            item.state = c.rawValue == note.color ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Paper", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for style in ["plain", "lined", "grid"] {
            let item = NSMenuItem(title: style.capitalized, action: #selector(pickPaper(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            item.state = (note.paper ?? "plain") == style ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func shareMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        item("Copy as Text", #selector(copyText))
        item("Copy as Markdown", #selector(copyMarkdown))
        item("Save as Markdown File…", #selector(saveMarkdownFile))
        menu.addItem(.separator())
        item("Share…", #selector(systemShare))
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ target: AnyObject = self) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = target
            menu.addItem(i)
        }
        item("All Notes…", #selector(openBoard))
        item("New Note", #selector(newNote))
        menu.addItem(.separator())
        item("Help", #selector(openHelp))
        menu.addItem(.separator())
        item("Delete This Note…", #selector(deleteThisNote))
        menu.addItem(.separator())
        item("Quit Stick-It", #selector(NSApplication.terminate(_:)), NSApp)
        return menu
    }

    @objc private func openBoard() { BoardWindow.shared.show() }
    @objc private func openHelp() { HelpWindow.shared.show() }
    @objc private func newNote() { NoteManager.shared.newNote() }

    @objc private func deleteThisNote() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.title)”?"
        alert.informativeText = "This permanently deletes the note. You can't undo this."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NoteManager.shared.deleteNote(note.id)
        }
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        note.color = sender.representedObject as! String
        let hex = (NoteColor(rawValue: note.color) ?? .yellow).hex
        webView.evaluateJavaScript("setColor('\(hex)')")
        NoteStore.shared.save(note)
    }

    @objc private func pickPaper(_ sender: NSMenuItem) {
        let style = sender.representedObject as! String
        note.paper = style == "plain" ? nil : style
        webView.evaluateJavaScript("setPaper('\(style)')")
        NoteStore.shared.save(note)
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    @objc private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.md, forType: .string)
    }

    @objc private func saveMarkdownFile() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            try? self.note.md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func systemShare() {
        let picker = NSSharingServicePicker(items: [note.text])
        picker.show(relativeTo: .zero, of: webView, preferredEdge: .minY)
    }

    // MARK: state

    private func applyPin() {
        guard let window else { return }
        window.level = note.pinned ? .floating : .normal
        window.collectionBehavior = note.pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        if loaded { webView.evaluateJavaScript("setPinned(\(note.pinned))") }
    }

    private func toggleCollapsed() {
        guard let window else { return }
        note.collapsed.toggle()
        let collapsing = note.collapsed
        var frame = window.frame
        if collapsing {
            expandedHeight = frame.height
            frame.origin.y += frame.height - Self.barHeight
            frame.size.height = Self.barHeight
        } else {
            let newH = max(expandedHeight, 200)
            frame.origin.y -= newH - frame.height
            frame.size.height = newH
            // reveal content immediately so it's laid out and visible as the window grows into it
            webView.evaluateJavaScript("setCollapsed(false)")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            // hide content only after the shrink finishes, so it visibly rolls away rather
            // than vanishing instantly while the window is still animating around it
            if collapsing { self?.webView.evaluateJavaScript("setCollapsed(true)") }
        })
        window.invalidateShadow()
        NoteStore.shared.save(note)
    }

    func windowDidMove(_ notification: Notification) {
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func saveFrame() {
        guard let f = window?.frame else { return }
        note.x = f.origin.x
        note.y = f.origin.y
        note.w = f.width
        note.h = note.collapsed ? expandedHeight : f.height
        if !note.collapsed { expandedHeight = f.height }
        NoteStore.shared.save(note)
    }

    private func clampToScreen() {
        guard let window else { return }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        if !visible.intersects(window.frame) {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
    }

    func focusNote() {
        if !note.open {
            note.open = true
            NoteStore.shared.save(note)
        }
        if note.collapsed { toggleCollapsed() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        for name in ["save", "peel", "ui", "win"] {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }
}

final class NavDelegate: NSObject, WKNavigationDelegate {
    let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad() }
}

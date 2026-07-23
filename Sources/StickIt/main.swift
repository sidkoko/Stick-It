import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class NoteManager {
    static let shared = NoteManager()
    private var controllers: [String: NoteWindowController] = [:]
    private var colorRotation = 0

    func restoreOpenNotes() {
        let open = NoteStore.shared.all.filter { $0.open }
        if NoteStore.shared.all.isEmpty {
            newNote(welcome: true)
            return
        }
        for note in open { show(note) }
    }

    func show(_ noteIn: Note) {
        var note = noteIn
        if let c = controllers[note.id] { c.focusNote(); return }
        if !note.open {
            note.open = true
            NoteStore.shared.save(note)
        }
        let c = NoteWindowController(note: note)
        controllers[note.id] = c
        c.focusNote()
    }

    // Wide enough that the full formatting toolbar (incl. all 4 text colors) fits
    // without scrolling — the toolbar needs ~431px at natural width.
    static let defaultSize = NSSize(width: 440, height: 380)

    func newNote(welcome: Bool = false) {
        var note = Note()
        let colors = NoteColor.allCases
        note.color = colors[colorRotation % colors.count].rawValue
        colorRotation += 1
        let size = welcome ? NSSize(width: 460, height: 460) : Self.defaultSize
        note.w = size.width
        note.h = size.height
        // appear near the mouse, nudged so the cursor lands on the note
        let mouse = NSEvent.mouseLocation
        note.x = mouse.x - 40
        note.y = mouse.y - note.h + 20
        if welcome {
            note.html = Self.welcomeHTML
            note.text = "Welcome to Stick-It!"
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            note.x = screen.midX - note.w / 2
            note.y = screen.midY - note.h / 2
        }
        NoteStore.shared.save(note)
        show(note)
    }

    // A page torn off the pad: the fresh note appears underneath the old one,
    // at the exact same spot, revealed as the old note peels away. Returns the new note's id
    // so the caller can discard it again if the peel gets cancelled before it detaches.
    @discardableResult
    func spawnNoteUnder(current: NoteWindowController) -> String? {
        guard let curWindow = current.window else { return nil }
        var note = Note()
        let colors = NoteColor.allCases
        note.color = colors[colorRotation % colors.count].rawValue
        colorRotation += 1
        let f = curWindow.frame
        note.x = f.origin.x
        note.y = f.origin.y
        note.w = f.width
        note.h = f.height
        note.pinned = current.note.pinned
        NoteStore.shared.save(note)
        let c = NoteWindowController(note: note)
        controllers[note.id] = c
        c.window?.order(.below, relativeTo: curWindow.windowNumber)
        return note.id
    }

    // Cancelled peel: the revealed page underneath was never touched, so it can vanish quietly.
    func discardIfUntouched(_ id: String) {
        guard let note = NoteStore.shared.notes[id], note.text.isEmpty, note.drawing == nil else { return }
        deleteNote(id)
    }

    func deleteNote(_ id: String) {
        controllers[id]?.close()
        controllers[id] = nil
        NoteStore.shared.delete(id)
    }

    static let welcomeHTML = """
    <h1>Welcome to Stick-It! 👋</h1>
    <div>This note is yours — edit it, or hide it with the ✕ up top.</div>
    <div><br></div>
    <div><b>Try this:</b></div>
    <ul class="cl">
      <li><input type="checkbox" contenteditable="false">Click a checkbox — satisfying, right?</li>
      <li><input type="checkbox" contenteditable="false">Type <b>[]</b> then space for a new checklist</li>
      <li><input type="checkbox" contenteditable="false">Type <b>-</b> then space for bullets, <b>#</b> for a heading</li>
      <li><input type="checkbox" contenteditable="false">Select text, then use the toolbar to style it</li>
      <li><input type="checkbox" contenteditable="false">Press <b>⌥⌘N</b> anywhere for a new note</li>
      <li><input type="checkbox" contenteditable="false"><b>Pull the curled corner</b> ↘ to tear a fresh page off the pad</li>
      <li><input type="checkbox" contenteditable="false">Hit <b>✏️</b> up top and doodle on me</li>
      <li><input type="checkbox" contenteditable="false">Click <b>⋯</b> up top for All Notes, Help, and more</li>
    </ul>
    <div><br></div>
    <div>Type a name straight into the bar up top. 📌 pins a note on top of everything, on every desktop. Everything saves itself.</div>
    """
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Stick-It") {
            statusItem.button?.image = icon
        } else {
            // guarantees something visible shows up even if the SF Symbol fails to resolve
            statusItem.button?.title = "📝"
        }

        let menu = NSMenu()
        let newItem = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .option]
        newItem.target = self
        menu.addItem(newItem)
        menu.addItem(menuItem("All Notes…", #selector(showBoard)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Help", #selector(showHelp)))
        let loginItem = menuItem("Launch at Login", #selector(toggleLaunchAtLogin))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Stick-It", #selector(NSApplication.terminate(_:)), target: NSApp))
        menu.delegate = self
        self.loginMenuItem = loginItem
        statusItem.menu = menu

        installEditMenu()
        registerHotkey()
        NoteManager.shared.restoreOpenNotes()
    }

    // This app has no visible menu bar (it's a background/accessory app), so without this,
    // macOS has no menu claiming ⌘C/⌘V/etc. and never routes them anywhere — the WKWebView
    // in every note already implements cut/copy/paste/select-all, it just needs something to
    // send the key equivalent to it. Deliberately omits Undo/Redo — that's meant to do nothing.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Quit Stick-It", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: Selector(("cut:")), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    private var loginMenuItem: NSMenuItem!

    private func menuItem(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    @objc func newNote() { NoteManager.shared.newNote() }
    @objc func showBoard() { BoardWindow.shared.show() }
    @objc func showHelp() { HelpWindow.shared.show() }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func registerHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { NoteManager.shared.newNote() }
            return noErr
        }, 1, &eventType, nil, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x53544B49), id: 1) // "STKI"

        // ⌥⌘N first; if something else already owns that combo, fall back to ⌃⌥⌘N
        // rather than silently doing nothing forever.
        var status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey),
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey | controlKey),
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        }
        if status != noErr {
            NSLog("Stick-It: could not register a global hotkey (status \(status)) — New Note is still available from the menu bar.")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AppKit
import SwiftUI

final class BoardWindow {
    static let shared = BoardWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "All Notes"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentViewController = NSHostingController(rootView: BoardView())
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct BoardView: View {
    @State private var notes: [Note] = NoteStore.shared.all
    @State private var query = ""
    @State private var selectMode = false
    @State private var selected: Set<String> = []
    @State private var activeGroup: String? = nil   // nil = "All"
    @State private var backTargeted = false
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBase: Set<String> = []
    @State private var marqueeIgnoring = false
    @State private var updateInfo: UpdateChecker.ReleaseInfo?
    @AppStorage("dismissedUpdateVersion") private var dismissedVersion = ""

    // Distinct group names in use, alphabetical — a group only exists as long as some
    // note still points at it, so this list needs no separate store to stay in sync.
    private var groups: [String] {
        Set(notes.compactMap { $0.group?.isEmpty == false ? $0.group : nil }).sorted()
    }

    // Folders shown as single cards on the top-level grid — only when you're actually
    // looking at the top level with nothing typed. The moment you search, folders would
    // just hide the note you're looking for, so search reaches straight through them.
    private var topLevelFolders: [String] {
        activeGroup == nil && query.isEmpty ? groups : []
    }

    private func matchesQuery(_ note: Note) -> Bool {
        query.isEmpty || note.text.localizedCaseInsensitiveContains(query)
            || note.title.localizedCaseInsensitiveContains(query)
    }

    // The individual note cards on the grid: inside a folder (or mid-search) that's every
    // matching note; at the top level with no search it's only the ungrouped ones — their
    // grouped siblings are standing in as folder cards instead of appearing twice.
    private var gridNotes: [Note] {
        if let g = activeGroup {
            return notes.filter { $0.group == g }.filter(matchesQuery)
        }
        let base = query.isEmpty ? notes.filter { ($0.group ?? "").isEmpty } : notes
        return base.filter(matchesQuery)
    }

    private var marqueeRect: CGRect? {
        guard let a = marqueeStart, let b = marqueeCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // Click-drag over empty grid space box-selects, like Finder — starting the drag on a
    // card instead leaves it alone, so the card's own tap/drag-to-group gesture still
    // gets first say. Auto-enables Select mode, same as dragging an icon on the desktop
    // needs no "select mode" of its own.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("board"))
            .onChanged { value in
                if marqueeStart == nil {
                    let onACard = cardFrames.values.contains { $0.contains(value.startLocation) }
                    marqueeIgnoring = onACard
                    guard !onACard else { return }
                    marqueeStart = value.startLocation
                    marqueeBase = NSEvent.modifierFlags.contains(.shift) ? selected : []
                    if !selectMode { selectMode = true }
                }
                guard !marqueeIgnoring else { return }
                marqueeCurrent = value.location
                guard let rect = marqueeRect else { return }
                let hitIDs = cardFrames.filter { !$0.key.hasPrefix("group:") && rect.intersects($0.value) }.map(\.key)
                selected = marqueeBase.union(hitIDs)
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeIgnoring = false
            }
    }

    private func frameReporter(key: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: CardFramePreferenceKey.self, value: [key: geo.frame(in: .named("board"))])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let info = updateInfo, info.version != dismissedVersion {
                UpdateBanner(info: info) { dismissedVersion = info.version }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes…", text: $query)
                    .textFieldStyle(.plain)
                if selectMode {
                    Text("\(selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(selected.count == gridNotes.count ? "Deselect All" : "Select All") {
                        if selected.count == gridNotes.count {
                            selected.removeAll()
                        } else {
                            selected = Set(gridNotes.map(\.id))
                        }
                    }
                    Button { promptGroup(for: selected) } label: {
                        Label("Group…", systemImage: "folder")
                    }
                    .disabled(selected.isEmpty)
                    Button(role: .destructive) { confirmBatchDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selected.isEmpty)
                    Button("Cancel") {
                        selectMode = false
                        selected.removeAll()
                    }
                } else {
                    Button { selectMode = true } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    Button {
                        NoteManager.shared.newNote()
                    } label: {
                        Label("New Note", systemImage: "plus")
                    }
                    Button {
                        HelpWindow.shared.show()
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                }
            }
            .padding(12)
            // Folder cards are already the way in — a picker that does the same thing a
            // second time is the confusing part. The only thing genuinely missing is a way
            // back out, so that's the only control this row exists for.
            if let g = activeGroup {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        activeGroup = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text("All Notes").font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Text("/").foregroundStyle(.tertiary)
                    Label(g, systemImage: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Dragging a note out to "All Notes" mirrors the way back in: drop it on
                // a folder card to join, drop it here to leave.
                .background(backTargeted ? Color.accentColor.opacity(0.12) : .clear)
                .dropDestination(for: String.self) { ids, _ in
                    assignGroup(Set(ids), to: nil)
                    return true
                } isTargeted: { backTargeted = $0 }
            }
            Divider()
            if topLevelFolders.isEmpty && gridNotes.isEmpty {
                Spacer()
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                            ForEach(topLevelFolders, id: \.self) { g in
                                GroupCard(name: g, count: notes.filter { $0.group == g }.count) {
                                    activeGroup = g
                                } onDrop: { id in
                                    assignGroup(Set([id]), to: g)
                                }
                                .background(frameReporter(key: "group:\(g)"))
                            }
                            ForEach(gridNotes, id: \.id) { note in
                                // Inside its own folder the badge would just repeat the
                                // breadcrumb — only worth showing when a search reached past
                                // folder boundaries and the group isn't otherwise obvious.
                                NoteCard(note: note, selectMode: selectMode,
                                         isSelected: selected.contains(note.id),
                                         showGroupBadge: activeGroup == nil,
                                         onToggleSelect: {
                                    if selected.contains(note.id) { selected.remove(note.id) }
                                    else { selected.insert(note.id) }
                                }, onRemoveFromGroup: {
                                    assignGroup(Set([note.id]), to: nil)
                                })
                                .background(frameReporter(key: note.id))
                            }
                        }
                        .coordinateSpace(name: "board")
                        // Without this, the empty gaps between cards have no hit-testable
                        // surface of their own — a layout container only responds to a
                        // gesture where its children actually render content, so a drag
                        // starting in the gap (exactly where a marquee needs to start) was
                        // silently falling through to nothing.
                        .contentShape(Rectangle())
                        .gesture(marqueeGesture)
                        // Clicking empty space (a plain click, not a drag — DragGesture's
                        // minimumDistance means marqueeGesture never sees this) clears the
                        // selection, same as Finder. A tap that lands on a card is still the
                        // card's own onTapGesture; this only ever fires for the gaps.
                        .onTapGesture {
                            if selectMode { selected.removeAll() }
                        }
                        .overlay(alignment: .topLeading) {
                            if let rect = marqueeRect {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.12))
                                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onPreferenceChange(CardFramePreferenceKey.self) { cardFrames = $0 }
                        .padding(14)
                        .id("gridTop")
                    }
                    .overlay(alignment: .top) {
                        // Folder cards always sit at the top of the grid, so "scroll toward
                        // where I can drop this" only ever means one place — a plain jump-
                        // to-top beats building real incremental autoscroll for that.
                        if !topLevelFolders.isEmpty {
                            ScrollUpDropZone {
                                withAnimation { proxy.scrollTo("gridTop", anchor: .top) }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in
            notes = NoteStore.shared.all
            // The active filter can outlive its group — its last note got deleted or
            // regrouped elsewhere — in which case falling back to "All" beats showing
            // an empty grid for a group that no longer exists.
            if let g = activeGroup, !groups.contains(g) { activeGroup = nil }
        }
        .task {
            guard let latest = await UpdateChecker.fetchLatest(),
                  UpdateChecker.isNewer(latest.version, than: UpdateChecker.currentVersion) else { return }
            updateInfo = latest
        }
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "No notes match “\(query)”" }
        if let g = activeGroup { return "No notes in “\(g)”" }
        return "No notes yet — make one!"
    }

    // A group is just a shared string on each note — no separate entity to keep in sync.
    // Shared by the Select→Group… dialog (batch, can create/rename a group) and drag-drop
    // (single note, only ever moves it into or out of a group that already has a card).
    private func assignGroup(_ ids: Set<String>, to name: String?) {
        let name = name?.trimmingCharacters(in: .whitespaces)
        for id in ids {
            guard var note = NoteStore.shared.notes[id] else { continue }
            note.group = (name?.isEmpty ?? true) ? nil : name
            NoteStore.shared.save(note)
        }
    }

    private func promptGroup(for ids: Set<String>) {
        let alert = NSAlert()
        let count = ids.count
        alert.messageText = "Group \(count) note\(count == 1 ? "" : "s")"
        alert.informativeText = "Enter a group name, or clear it to ungroup."
        alert.addButton(withTitle: "Group")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let current = Set(ids.compactMap { NoteStore.shared.notes[$0]?.group })
        field.stringValue = current.count == 1 ? (current.first ?? "") : ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        assignGroup(ids, to: field.stringValue)
        selectMode = false
        selected.removeAll()
    }

    private func confirmBatchDelete() {
        let count = selected.count
        let alert = NSAlert()
        alert.messageText = "Delete \(count) note\(count == 1 ? "" : "s")?"
        alert.informativeText = "This permanently deletes them. You can't undo this."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            for id in selected { NoteManager.shared.deleteNote(id) }
            selected.removeAll()
            selectMode = false
        }
    }
}

// Collects each card's on-screen frame (in the grid's own "board" coordinate space) so
// the marquee-drag gesture can hit-test against them. Note ids and group cards share
// this dictionary; group entries are keyed "group:<name>" so the selection math (which
// only ever selects notes) can filter them out by key prefix alone.
private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct UpdateBanner: View {
    let info: UpdateChecker.ReleaseInfo
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Stick-It \(info.version) is available")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("View") { NSWorkspace.shared.open(info.url) }
                .font(.system(size: 12))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}

/// A thin band pinned to the top edge of the note grid — hover a drag over it and the
/// grid jumps back up to where the folder cards live, so a note buried under a long
/// scroll of other notes can still reach a folder without a second hand on the trackpad.
struct ScrollUpDropZone: View {
    let scrollToTop: () -> Void
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted ? Color.accentColor.opacity(0.15) : .clear)
            .frame(height: 28)
            .overlay(alignment: .top) {
                if isTargeted {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { _, _ in false } isTargeted: { targeted in
                isTargeted = targeted
                if targeted { scrollToTop() }
            }
    }
}

/// A folder standing in for every note sharing its group name — tap to open it and see
/// the notes inside. Neutral gray, deliberately not a sticky color, so it reads as a
/// container rather than another note.
struct GroupCard: View {
    let name: String
    let count: Int
    let action: () -> Void
    var onDrop: (String) -> Void = { _ in }
    @State private var isTargeted = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(count) note\(count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isTargeted ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("Open “\(name)” — drop a note here to add it")
        .dropDestination(for: String.self) { ids, _ in
            ids.forEach(onDrop)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct NoteCard: View {
    let note: Note
    var selectMode: Bool = false
    var isSelected: Bool = false
    var showGroupBadge: Bool = true
    var onToggleSelect: () -> Void = {}
    var onRemoveFromGroup: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if selectMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .black.opacity(0.3))
                }
                Text(note.title).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
            }
            .foregroundStyle(.black.opacity(0.75))
            if showGroupBadge, let group = note.group, !group.isEmpty {
                Text(group)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.black.opacity(0.5))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.08))
                    .clipShape(Capsule())
            }
            Text(body_(note))
                .font(.system(size: 11))
                .foregroundStyle(.black.opacity(0.6))
                .lineLimit(6, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 10))
                    .foregroundStyle(.black.opacity(0.4))
                Spacer()
                if !selectMode {
                    cardButton("arrow.up.forward.square", "Open this note") {
                        NoteManager.shared.show(note)
                    }
                    cardButton("doc.on.doc", "Copy note as text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                    }
                    cardButton("trash", "Delete this note…") { confirmDelete() }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: (NoteColor(rawValue: note.color) ?? .yellow).nsColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .onTapGesture {
            if selectMode { onToggleSelect() } else { NoteManager.shared.show(note) }
        }
        // Drag onto a folder card to join it, or onto "All Notes" (while inside a folder)
        // to leave.
        .draggable(note.id)
        .contextMenu {
            Button("Open") { NoteManager.shared.show(note) }
            Button("Copy as Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.md, forType: .string)
            }
            if let group = note.group, !group.isEmpty {
                Divider()
                Button("Remove from “\(group)”") { onRemoveFromGroup() }
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete() }
        }
        .help(selectMode ? "Click to select" : "Click to open")
    }

    private func cardButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.black.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func body_(_ note: Note) -> String {
        let lines = note.text.split(separator: "\n").map(String.init)
        return lines.dropFirst().joined(separator: "\n")
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.title)”?"
        alert.informativeText = "This permanently deletes the note. You can't undo this."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NoteManager.shared.deleteNote(note.id)
        }
    }
}

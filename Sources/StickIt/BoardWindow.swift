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

    private var filtered: [Note] {
        query.isEmpty ? notes
            : notes.filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes…", text: $query)
                    .textFieldStyle(.plain)
                if selectMode {
                    Text("\(selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text(query.isEmpty ? "No notes yet — make one!" : "No notes match “\(query)”")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                        ForEach(filtered, id: \.id) { note in
                            NoteCard(note: note, selectMode: selectMode, isSelected: selected.contains(note.id)) {
                                if selected.contains(note.id) { selected.remove(note.id) }
                                else { selected.insert(note.id) }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in
            notes = NoteStore.shared.all
        }
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

struct NoteCard: View {
    let note: Note
    var selectMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: () -> Void = {}

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

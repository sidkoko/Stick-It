import AppKit

struct Note: Codable {
    var id: String = UUID().uuidString
    var name: String?
    var paper: String?      // nil = plain, "lined", "grid"
    var drawing: String?    // PNG data URL of the sketch layer
    var html: String = ""
    var text: String = ""
    var md: String = ""
    var color: String = "yellow"
    var x: Double = 0, y: Double = 0, w: Double = 300, h: Double = 280
    var pinned: Bool = true
    var collapsed: Bool = false
    var open: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var title: String {
        if let name, !name.isEmpty { return name }
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "New Note"
        return String(line.prefix(48))
    }
}

enum NoteColor: String, CaseIterable {
    case yellow, pink, blue, green, orange, purple

    var hex: String {
        switch self {
        case .yellow: return "#FFF3A3"
        case .pink:   return "#FFD1E3"
        case .blue:   return "#C9E8FF"
        case .green:  return "#D5F2C2"
        case .orange: return "#FFDDB0"
        case .purple: return "#E6D9FF"
        }
    }

    var nsColor: NSColor {
        let hexValue = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFF3A3
        return NSColor(
            red: CGFloat((hexValue >> 16) & 0xFF) / 255,
            green: CGFloat((hexValue >> 8) & 0xFF) / 255,
            blue: CGFloat(hexValue & 0xFF) / 255,
            alpha: 1
        )
    }

    // slightly darker shade for the note's title bar
    var barColor: NSColor { nsColor.blended(withFraction: 0.08, of: .black) ?? nsColor }
}

extension Notification.Name {
    static let notesChanged = Notification.Name("notesChanged")
}

final class NoteStore {
    static let shared = NoteStore()

    let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Stick-It/notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private(set) var notes: [String: Note] = [:]

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let n = try? JSONDecoder().decode(Note.self, from: data) {
                notes[n.id] = n
            }
        }
    }

    var all: [Note] { notes.values.sorted { $0.updatedAt > $1.updatedAt } }

    func save(_ note: Note) {
        notes[note.id] = note
        if let data = try? JSONEncoder().encode(note) {
            try? data.write(to: dir.appendingPathComponent(note.id + ".json"), options: .atomic)
        }
        NotificationCenter.default.post(name: .notesChanged, object: nil)
    }

    func delete(_ id: String) {
        notes[id] = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json"))
        NotificationCenter.default.post(name: .notesChanged, object: nil)
    }
}

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::Manager;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct NoteImage {
    pub id: String,
    pub src: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

// Field names mirror Sources/StickIt/NoteStore.swift's `Note` so the on-disk
// shape stays consistent across platforms, even though the two stores are
// otherwise fully independent (no sync between them today).
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub name: Option<String>,
    pub paper: Option<String>,
    pub drawing: Option<String>,
    #[serde(default)]
    pub html: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub md: String,
    pub images: Option<Vec<NoteImage>>,
    pub color: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub pinned: bool,
    pub collapsed: bool,
    pub open: bool,
    // ponytail: unix-seconds, not Swift's Core Data reference-date epoch —
    // fine for now since the stores don't sync; revisit only if that changes.
    pub created_at: f64,
    pub updated_at: f64,
}

impl Note {
    pub fn new() -> Self {
        let now = now_secs();
        Note {
            id: uuid::Uuid::new_v4().to_string(),
            name: None,
            paper: None,
            drawing: None,
            html: String::new(),
            text: String::new(),
            md: String::new(),
            images: None,
            color: "yellow".into(),
            x: 0.0,
            y: 0.0,
            w: 440.0,
            h: 380.0,
            pinned: true,
            collapsed: false,
            open: true,
            created_at: now,
            updated_at: now,
        }
    }

    // Mirrors Note.title in Sources/StickIt/NoteStore.swift.
    pub fn title(&self) -> String {
        if let Some(name) = &self.name {
            if !name.is_empty() {
                return name.clone();
            }
        }
        for line in self.text.split('\n') {
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                return trimmed.chars().take(48).collect();
            }
        }
        "New Note".to_string()
    }
}

pub fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()
}

pub fn notes_dir(app: &tauri::AppHandle) -> PathBuf {
    app.path().app_data_dir().unwrap().join("notes")
}

pub fn save(app: &tauri::AppHandle, note: &Note) -> std::io::Result<()> {
    let dir = notes_dir(app);
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}.json", note.id));
    fs::write(path, serde_json::to_vec_pretty(note)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises the serialization path directly (a real AppHandle needs a
    // running Tauri app, so this skips notes_dir/save's app.path() lookup and
    // just proves the schema — camelCase keys matching NoteStore.swift, round
    // trips through serde_json cleanly).
    #[test]
    fn note_round_trips_with_swift_compatible_field_names() {
        let mut note = Note::new();
        note.html = "<div>hi</div>".into();
        note.images = Some(vec![NoteImage { id: "img1".into(), src: "data:...".into(), x: 1.0, y: 2.0, w: 3.0, h: 4.0 }]);

        let json = serde_json::to_string_pretty(&note).unwrap();
        assert!(json.contains("\"createdAt\""));
        assert!(json.contains("\"updatedAt\""));
        assert!(!json.contains("created_at"));

        let parsed: Note = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, note.id);
        assert_eq!(parsed.color, "yellow");
        assert_eq!(parsed.images.unwrap()[0].id, "img1");
    }
}

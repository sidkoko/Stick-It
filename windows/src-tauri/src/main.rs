// Full Windows scaffold: editor.html runs unmodified in Tauri's webview, multi-note
// windows persist across restarts, drag/resize/pin are real, and now peel-to-new-note,
// the color/paper/share/more menus, collapse, the All Notes board, and the Help window
// are all implemented too — mirroring Sources/StickIt/{main,NoteWindow,BoardWindow,
// HelpWindow}.swift. See the Windows scoping plan
// (~/.claude/plans/wild-imagining-crystal.md) for the still-open platform gaps
// (no cross-desktop pin, no native Share sheet, approximate window shadow/corners).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod note_store;

use note_store::{Note, NoteImage};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use tauri::{
    image::Image,
    menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::TrayIconBuilder,
    webview::PageLoadEvent,
    AppHandle, LogicalPosition, LogicalSize, Manager, Position, Size, State, WebviewUrl,
    WebviewWindowBuilder, Wry,
};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_clipboard_manager::ClipboardExt as _;
use tauri_plugin_dialog::{DialogExt as _, MessageDialogButtons};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

// Keyed by note id, which doubles as the window label — one entry per *open* note
// window. Mirrors NoteManager.controllers in Sources/StickIt/main.swift. Notes that
// exist on disk but aren't open live there only, read fresh by list_notes().
struct Notes(Mutex<HashMap<String, Note>>);
// Logical-pixel (x, y) at the start of a drag, and (x, y, w, h) at the start of a
// resize, keyed by window label — mirrors dragStart/resizeStart in NoteWindow.swift.
struct DragState(Mutex<HashMap<String, (f64, f64)>>);
struct ResizeState(Mutex<HashMap<String, (f64, f64, f64, f64)>>);
// Per-window peel state, keyed by the *original* (being-torn-off) window's label —
// mirrors spawnedID/peelStart in NoteWindowController.
#[derive(Default, Clone)]
struct PeelInfo {
    spawned_id: Option<String>,
    peel_start: Option<(f64, f64)>,
}
struct PeelState(Mutex<HashMap<String, PeelInfo>>);

const MIN_W: f64 = 320.0;
const MIN_H: f64 = 200.0;
const BAR_HEIGHT: f64 = 30.0; // matches NoteWindowController.barHeight / editor.html's #bar
const TRAY_ICON_BYTES: &[u8] = include_bytes!("../icons/icon.png");
const TRAY_ID: &str = "stickit-tray";
const RECENT_COUNT: usize = 6; // matches AppDelegate.recentCount on macOS
// Fingerprint of the recents list as the tray last drew it, so a rebuild only happens
// when the menu would actually look different — see refresh_tray_menu.
static LAST_RECENTS: Mutex<String> = Mutex::new(String::new());

// Mirrors NoteColor.hex in Sources/StickIt/NoteStore.swift.
fn hex_for_color(color: &str) -> &'static str {
    match color {
        "pink" => "#FFD1E3",
        "blue" => "#C9E8FF",
        "green" => "#D5F2C2",
        "orange" => "#FFDDB0",
        "purple" => "#E6D9FF",
        _ => "#FFF3A3", // yellow, and the fallback
    }
}

const NOTE_COLORS: [&str; 6] = ["yellow", "pink", "blue", "green", "orange", "purple"];
static COLOR_ROTATION: AtomicU32 = AtomicU32::new(0);

// Mirrors NoteManager.colorRotation — every new note (regular or torn off a peel)
// gets the next color in the cycle, not a copy of whatever note spawned it.
fn next_color() -> &'static str {
    let i = COLOR_ROTATION.fetch_add(1, Ordering::Relaxed) as usize % NOTE_COLORS.len();
    NOTE_COLORS[i]
}

fn title_case(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(f) => f.to_uppercase().collect::<String>() + chars.as_str(),
    }
}

fn with_note<T>(notes: &State<Notes>, label: &str, f: impl FnOnce(&mut Note) -> T) -> Option<T> {
    notes.0.lock().unwrap().get_mut(label).map(f)
}

/// Deletes a note's window (if open), its in-memory entry, and its file on disk.
/// Reused by the "Delete This Note" menu action and the All Notes board.
fn delete_note(app: &AppHandle, note_id: &str) {
    if let Some(w) = app.get_webview_window(note_id) {
        let _ = w.destroy();
    }
    app.state::<Notes>().0.lock().unwrap().remove(note_id);
    let path = note_store::notes_dir(app).join(format!("{note_id}.json"));
    let _ = std::fs::remove_file(path);
    // The only note mutation that doesn't route through note_store::save().
    refresh_tray_menu(app);
}

/// Mirrors NoteManager.discardIfUntouched(): a peeled-then-abandoned page vanishes
/// quietly if the user never actually wrote or drew anything on it.
fn discard_if_untouched(app: &AppHandle, note_id: &str) {
    let untouched = app
        .state::<Notes>()
        .0
        .lock()
        .unwrap()
        .get(note_id)
        .map(|n| n.text.trim().is_empty() && n.drawing.is_none())
        .unwrap_or(false);
    if untouched {
        delete_note(app, note_id);
    }
}

fn show_help_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("help") {
        let _ = w.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "help", WebviewUrl::App("help.html".into()))
        .title("Stick-It Help")
        .inner_size(560.0, 620.0)
        .resizable(true)
        .build();
}

fn show_board_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("board") {
        let _ = w.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "board", WebviewUrl::App("board.html".into()))
        .title("All Notes")
        .inner_size(640.0, 480.0)
        .resizable(true)
        .build();
}

#[tauri::command]
fn save(
    app: AppHandle,
    window: tauri::WebviewWindow,
    notes: State<Notes>,
    html: String,
    text: String,
    md: String,
    drawing: String,
    images: Vec<NoteImage>,
) -> Result<(), String> {
    let saved = with_note(&notes, window.label(), |note| {
        note.html = html;
        note.text = text;
        note.md = md;
        note.drawing = if drawing.is_empty() { None } else { Some(drawing) };
        note.images = Some(images);
        note.updated_at = note_store::now_secs();
        note.clone()
    });
    match saved {
        Some(note) => note_store::save(&app, &note).map_err(|e| e.to_string()),
        None => Ok(()),
    }
}

// Tauri's window position/size is top-left-origin on every platform (unlike AppKit's
// flipped bottom-left origin), so unlike NoteWindow.swift's handleWin, no y-flip is
// needed for drag; the 'n' resize case is the one that differs from the Swift
// version's math because of that same coordinate difference — see the inline note.
#[tauri::command]
fn win(
    app: AppHandle,
    window: tauri::WebviewWindow,
    notes: State<Notes>,
    drag: State<DragState>,
    resize: State<ResizeState>,
    phase: String,
    dx: Option<f64>,
    dy: Option<f64>,
    edge: Option<String>,
) -> Result<(), String> {
    let label = window.label().to_string();
    let scale = window.scale_factor().map_err(|e| e.to_string())?;
    let dx = dx.unwrap_or(0.0);
    let dy = dy.unwrap_or(0.0);
    // A collapsed note is one bar tall with its content hidden — resizing it would just
    // stretch a blank slab with nothing in it. editor.html hides the handles while
    // collapsed too; this covers any message that still arrives (in-flight drags, a
    // stale page). Mirrors the same guard in NoteWindow.swift's handleWin.
    if matches!(phase.as_str(), "resizeStart" | "resize")
        && with_note(&notes, &label, |n| n.collapsed).unwrap_or(false)
    {
        return Ok(());
    }
    match phase.as_str() {
        "dragStart" => {
            let pos = window
                .outer_position()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            drag.0.lock().unwrap().insert(label, (pos.x, pos.y));
        }
        "drag" => {
            if let Some(&(ox, oy)) = drag.0.lock().unwrap().get(&label) {
                window
                    .set_position(Position::Logical(LogicalPosition::new(ox + dx, oy + dy)))
                    .map_err(|e| e.to_string())?;
            }
        }
        "resizeStart" => {
            let pos = window
                .outer_position()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            let size = window
                .outer_size()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            resize
                .0
                .lock()
                .unwrap()
                .insert(label, (pos.x, pos.y, size.width, size.height));
        }
        "resize" => {
            if let Some(&(sx, sy, sw, sh)) = resize.0.lock().unwrap().get(&label) {
                let edge = edge.unwrap_or_default();
                let (mut x, mut y, mut w, mut h) = (sx, sy, sw, sh);

                // Cap growth to the current monitor's usable work area so the note can't
                // be resized larger than the screen (no equivalent bound exists on the
                // macOS side today, but there resizing is also mouse-limited by the
                // screen edge implicitly — here nothing stops the math from producing an
                // arbitrarily large window without this).
                let (max_w, max_h) = window
                    .current_monitor()
                    .ok()
                    .flatten()
                    .map(|m| {
                        let size = m.work_area().size.to_logical::<f64>(scale);
                        (size.width, size.height)
                    })
                    .unwrap_or((f64::MAX, f64::MAX));

                if edge.contains('e') {
                    w = (sw + dx).max(MIN_W).min(max_w);
                }
                if edge.contains('w') {
                    w = (sw - dx).max(MIN_W).min(max_w);
                    x = sx + sw - w;
                }
                if edge.contains('s') {
                    h = (sh + dy).max(MIN_H).min(max_h);
                }
                if edge.contains('n') {
                    // Swift's version doesn't adjust origin.y here because AppKit's
                    // bottom-left origin already keeps the bottom edge fixed when only
                    // height shrinks. Tauri's origin is top-left, so the top edge is the
                    // fixed point by default instead — we have to explicitly pin the
                    // *bottom* (sy + sh) and derive y from it to get the same "drag the
                    // top edge, bottom stays put" behavior.
                    h = (sh - dy).max(MIN_H).min(max_h);
                    y = sy + sh - h;
                }
                window
                    .set_position(Position::Logical(LogicalPosition::new(x, y)))
                    .map_err(|e| e.to_string())?;
                window
                    .set_size(Size::Logical(LogicalSize::new(w, h)))
                    .map_err(|e| e.to_string())?;
            }
        }
        "end" => {
            drag.0.lock().unwrap().remove(&label);
            resize.0.lock().unwrap().remove(&label);
            let pos = window
                .outer_position()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            let size = window
                .outer_size()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            let saved = with_note(&notes, &label, |note| {
                note.x = pos.x;
                note.y = pos.y;
                note.w = size.width;
                // While collapsed, the window's actual height is just the title bar —
                // don't clobber the real (expanded) height with that. Mirrors Swift's
                // `note.h = note.collapsed ? expandedHeight : f.height` in saveFrame().
                if !note.collapsed {
                    note.h = size.height;
                }
                note.clone()
            });
            if let Some(note) = saved {
                note_store::save(&app, &note).map_err(|e| e.to_string())?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Mirrors NoteWindowController.handlePeel(): tear a fresh page off the pad, revealing
/// a new sibling note underneath as the current one is dragged away.
#[tauri::command]
fn peel(
    app: AppHandle,
    window: tauri::WebviewWindow,
    notes: State<Notes>,
    peel_state: State<PeelState>,
    phase: String,
    dx: Option<f64>,
    dy: Option<f64>,
) -> Result<(), String> {
    let label = window.label().to_string();
    let dx = dx.unwrap_or(0.0);
    let dy = dy.unwrap_or(0.0);
    match phase.as_str() {
        "reveal" => {
            let already_spawned = peel_state
                .0
                .lock()
                .unwrap()
                .get(&label)
                .and_then(|p| p.spawned_id.clone())
                .is_some();
            if already_spawned {
                return Ok(());
            }
            let current = notes.0.lock().unwrap().get(&label).cloned();
            if let Some(cur) = current {
                let mut sibling = Note::new();
                sibling.color = next_color().to_string();
                sibling.x = cur.x;
                sibling.y = cur.y;
                sibling.w = cur.w;
                sibling.h = cur.h;
                sibling.pinned = cur.pinned;
                let sibling_id = sibling.id.clone();
                let _ = note_store::save(&app, &sibling);
                spawn_note_window(&app, sibling).map_err(|e| e.to_string())?;
                // The new sibling window is created on top by default; refocusing the
                // window still being dragged puts it back in front, which is what makes
                // the sibling read as "revealed underneath" rather than "popped on top".
                window.set_focus().map_err(|e| e.to_string())?;
                peel_state
                    .0
                    .lock()
                    .unwrap()
                    .entry(label.clone())
                    .or_default()
                    .spawned_id = Some(sibling_id);
            }
        }
        "detach" => {
            let mut guard = peel_state.0.lock().unwrap();
            let entry = guard.entry(label.clone()).or_default();
            entry.spawned_id = None; // the revealed page stays; this one is now loose
            let scale = window.scale_factor().map_err(|e| e.to_string())?;
            let pos = window
                .outer_position()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            entry.peel_start = Some((pos.x, pos.y));
        }
        "move" => {
            let start = peel_state
                .0
                .lock()
                .unwrap()
                .get(&label)
                .and_then(|p| p.peel_start);
            if let Some((ox, oy)) = start {
                window
                    .set_position(Position::Logical(LogicalPosition::new(ox + dx, oy + dy)))
                    .map_err(|e| e.to_string())?;
            }
        }
        "cancel" => {
            let spawned = peel_state
                .0
                .lock()
                .unwrap()
                .get_mut(&label)
                .and_then(|p| p.spawned_id.take());
            if let Some(sibling_id) = spawned {
                discard_if_untouched(&app, &sibling_id);
            }
        }
        "end" => {
            if let Some(p) = peel_state.0.lock().unwrap().get_mut(&label) {
                p.peel_start = None;
            }
            let scale = window.scale_factor().map_err(|e| e.to_string())?;
            let pos = window
                .outer_position()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            let size = window
                .outer_size()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(scale);
            let saved = with_note(&notes, &label, |note| {
                note.x = pos.x;
                note.y = pos.y;
                if !note.collapsed {
                    note.h = size.height;
                }
                note.w = size.width;
                note.clone()
            });
            if let Some(note) = saved {
                note_store::save(&app, &note).map_err(|e| e.to_string())?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[tauri::command]
fn ui(
    app: AppHandle,
    window: tauri::WebviewWindow,
    notes: State<Notes>,
    action: String,
    name: Option<String>,
    x: Option<f64>,
    y: Option<f64>,
) -> Result<(), String> {
    let label = window.label().to_string();
    match action.as_str() {
        "close" => {
            let saved = with_note(&notes, &label, |note| {
                note.open = false;
                note.clone()
            });
            if let Some(note) = saved {
                note_store::save(&app, &note).map_err(|e| e.to_string())?;
            }
            window.hide().map_err(|e| e.to_string())?;
        }
        "pin" => {
            let saved = with_note(&notes, &label, |note| {
                note.pinned = !note.pinned;
                note.clone()
            });
            if let Some(note) = saved {
                window
                    .set_always_on_top(note.pinned)
                    .map_err(|e| e.to_string())?;
                note_store::save(&app, &note).map_err(|e| e.to_string())?;
                // Missing this was the actual pin-toggle bug: the button's on/off look is
                // driven entirely by the page's own JS state (setPinned), which only
                // macOS's applyPin() was calling back into after a toggle — nothing did
                // that here, so the click "worked" (set_always_on_top did flip) but the
                // button never showed it.
                window
                    .eval(&format!("setPinned({})", note.pinned))
                    .map_err(|e| e.to_string())?;
            }
        }
        "rename" => {
            let saved = with_note(&notes, &label, |note| {
                let trimmed = name.clone().unwrap_or_default().trim().to_string();
                note.name = if trimmed.is_empty() { None } else { Some(trimmed) };
                note.updated_at = note_store::now_secs();
                note.clone()
            });
            if let Some(note) = saved {
                note_store::save(&app, &note).map_err(|e| e.to_string())?;
            }
        }
        "collapse" => {
            let saved = with_note(&notes, &label, |note| {
                note.collapsed = !note.collapsed;
                note.clone()
            });
            if let Some(note) = saved {
                let target_h = if note.collapsed { BAR_HEIGHT } else { note.h };
                window
                    .set_size(Size::Logical(LogicalSize::new(note.w, target_h)))
                    .map_err(|e| e.to_string())?;
                // No smooth animation like Swift's NSAnimationContext — an instant
                // snap is enough to prove the feature; add easing later if the lack
                // of animation reads as broken rather than just less polished.
                window
                    .eval(&format!("setCollapsed({})", note.collapsed))
                    .map_err(|e| e.to_string())?;
                note_store::save(&app, &note).map_err(|e| e.to_string())?;
            }
        }
        "colorMenu" => popup_color_menu(&app, &window, &notes, &label, x, y)?,
        "shareMenu" => popup_share_menu(&app, &window, &label, x, y)?,
        "moreMenu" => popup_more_menu(&app, &window, &label, x, y)?,
        other => println!("ui (not yet implemented): action={other} name={name:?}"),
    }
    Ok(())
}

fn popup_color_menu(
    app: &AppHandle,
    window: &tauri::WebviewWindow,
    notes: &State<Notes>,
    label: &str,
    x: Option<f64>,
    y: Option<f64>,
) -> Result<(), String> {
    let note = match notes.0.lock().unwrap().get(label).cloned() {
        Some(n) => n,
        None => return Ok(()),
    };
    let mut items: Vec<Box<dyn IsMenuItem<Wry>>> = Vec::new();
    for color in ["yellow", "pink", "blue", "green", "orange", "purple"] {
        let item = CheckMenuItem::with_id(
            app,
            format!("color:{color}:{label}"),
            title_case(color),
            true,
            note.color == color,
            None::<&str>,
        )
        .map_err(|e| e.to_string())?;
        items.push(Box::new(item));
    }
    items.push(Box::new(
        PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?,
    ));
    let current_paper = note.paper.clone().unwrap_or_else(|| "plain".into());
    for paper in ["plain", "lined", "grid"] {
        let item = CheckMenuItem::with_id(
            app,
            format!("paper:{paper}:{label}"),
            title_case(paper),
            true,
            current_paper == paper,
            None::<&str>,
        )
        .map_err(|e| e.to_string())?;
        items.push(Box::new(item));
    }
    let refs: Vec<&dyn IsMenuItem<Wry>> = items.iter().map(|b| b.as_ref()).collect();
    let menu = Menu::with_items(app, &refs).map_err(|e| e.to_string())?;
    window
        .popup_menu_at(
            &menu,
            Position::Logical(LogicalPosition::new(x.unwrap_or(0.0), y.unwrap_or(0.0))),
        )
        .map_err(|e| e.to_string())
}

fn popup_share_menu(
    app: &AppHandle,
    window: &tauri::WebviewWindow,
    label: &str,
    x: Option<f64>,
    y: Option<f64>,
) -> Result<(), String> {
    let copy_text = MenuItem::with_id(app, format!("copy_text:{label}"), "Copy as Text", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let copy_md = MenuItem::with_id(app, format!("copy_md:{label}"), "Copy as Markdown", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let save_md = MenuItem::with_id(
        app,
        format!("save_md:{label}"),
        "Save as Markdown File…",
        true,
        None::<&str>,
    )
    .map_err(|e| e.to_string())?;
    // No "Share…" — no Windows equivalent of NSSharingServicePicker worth building;
    // see the Windows scoping plan's limitations section.
    let menu = Menu::with_items(app, &[&copy_text, &copy_md, &save_md]).map_err(|e| e.to_string())?;
    window
        .popup_menu_at(
            &menu,
            Position::Logical(LogicalPosition::new(x.unwrap_or(0.0), y.unwrap_or(0.0))),
        )
        .map_err(|e| e.to_string())
}

fn popup_more_menu(
    app: &AppHandle,
    window: &tauri::WebviewWindow,
    label: &str,
    x: Option<f64>,
    y: Option<f64>,
) -> Result<(), String> {
    let all_notes = MenuItem::with_id(app, format!("all_notes:{label}"), "All Notes…", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let new_note = MenuItem::with_id(app, format!("new_note:{label}"), "New Note", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let help = MenuItem::with_id(app, format!("help:{label}"), "Help", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let delete = MenuItem::with_id(
        app,
        format!("delete_note:{label}"),
        "Delete This Note…",
        true,
        None::<&str>,
    )
    .map_err(|e| e.to_string())?;
    let quit = MenuItem::with_id(app, format!("quit:{label}"), "Quit Stick-It", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let menu = Menu::with_items(
        app,
        &[
            &all_notes,
            &new_note,
            &PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?,
            &help,
            &PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?,
            &delete,
            &PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?,
            &quit,
        ],
    )
    .map_err(|e| e.to_string())?;
    window
        .popup_menu_at(
            &menu,
            Position::Logical(LogicalPosition::new(x.unwrap_or(0.0), y.unwrap_or(0.0))),
        )
        .map_err(|e| e.to_string())
}

/// Mirrors NoteManager.show()/newNote() in Sources/StickIt/main.swift: registers the
/// note in the shared map and opens its window, pushing content once the page loads.
fn spawn_note_window(app: &AppHandle, note: Note) -> tauri::Result<()> {
    let id = note.id.clone();
    app.state::<Notes>().0.lock().unwrap().insert(id.clone(), note.clone());

    let handle = app.clone();
    let label = id.clone();
    let win_h = if note.collapsed { BAR_HEIGHT } else { note.h };
    WebviewWindowBuilder::new(app, &id, WebviewUrl::App("editor.html".into()))
        .title("Stick-It")
        .position(note.x, note.y)
        .inner_size(note.w, win_h)
        .decorations(false)
        .transparent(true)
        // PaperWindow on macOS uses styleMask: [.borderless] with no `.resizable` —
        // every resize goes through the custom edge handles + the clamped `win`
        // command, nothing else. Leaving this `true` gave the OS its own native
        // edge-resize with no minimum size, bypassing that clamp entirely.
        .resizable(false)
        // Tauri intercepts native file drag-and-drop at the window level by default
        // (needed on Windows, where WebView2 doesn't fire HTML5 DnD events on its
        // own) — that also swallows editor.html's own drop handler unless we opt out
        // and let the page handle it directly.
        .disable_drag_drop_handler()
        .on_page_load(move |window, payload| {
            if !matches!(payload.event(), PageLoadEvent::Finished) {
                return;
            }
            // Mirrors NoteWindowController.pushContent() on macOS — pushes the
            // in-memory note into the page once it's actually ready to receive it.
            let note = match handle.state::<Notes>().0.lock().unwrap().get(&label) {
                Some(n) => n.clone(),
                None => return,
            };
            let payload_json = serde_json::json!({
                "html": note.html,
                "hex": hex_for_color(&note.color),
                "paper": note.paper.clone().unwrap_or_else(|| "plain".into()),
                "drawing": note.drawing.clone().unwrap_or_default(),
                "name": note.name.clone().unwrap_or_default(),
                "pinned": note.pinned,
                "collapsed": note.collapsed,
                "images": note.images.clone().unwrap_or_default(),
            });
            let _ = window.eval(&format!("setNote({payload_json})"));
        })
        .build()?;
    Ok(())
}

/// Mirrors NoteManager.newNote() — used by both the tray "New Note" item, the global
/// hotkey, and the more-menu. Cascades position instead of following the cursor
/// (Tauri has no direct cursor-position query at this layer); real mouse-following
/// can follow if it turns out to matter.
fn spawn_new_note(app: &AppHandle) {
    static CASCADE: AtomicU32 = AtomicU32::new(0);
    let n = (CASCADE.fetch_add(1, Ordering::Relaxed) % 10) as f64;

    let mut note = Note::new();
    note.color = next_color().to_string();
    note.x = 120.0 + n * 28.0;
    note.y = 120.0 + n * 28.0;
    let _ = note_store::save(app, &note);
    let _ = spawn_note_window(app, note);
}

/// Mirrors NoteManager.restoreOpenNotes(): reopen every saved note that was left
/// open, or start fresh if there's nothing on disk yet. Skips the Swift welcome
/// note's sample HTML content for now — a blank first note is enough to prove the
/// restore path works; add the real copy back if first-run polish matters later.
fn restore_open_notes(app: &AppHandle) {
    let dir = note_store::notes_dir(app);
    let mut any_open = false;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if entry.path().extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(data) = std::fs::read_to_string(entry.path()) else { continue };
            let Ok(note) = serde_json::from_str::<Note>(&data) else { continue };
            if note.open {
                any_open = true;
                let _ = spawn_note_window(app, note);
            }
        }
    }
    if !any_open {
        spawn_new_note(app);
    }
}

/// Builds the whole tray menu, recents included. Takes the heads rather than reading
/// them again so a refresh only touches the disk once.
fn tray_menu(app: &AppHandle, recents: &[note_store::NoteHead]) -> tauri::Result<Menu<Wry>> {
    let mut items: Vec<Box<dyn IsMenuItem<Wry>>> = Vec::new();

    // Getting back to a note you already wrote shouldn't require knowing the All Notes
    // board exists — one click on the tray icon and they're right there. Mirrors
    // AppDelegate.rebuildRecents in Sources/StickIt/main.swift.
    // ponytail: text only, where the macOS menu draws a colour swatch per note
    // (NoteColor.swatch) — add IconMenuItem here if the dots turn out to matter.
    if !recents.is_empty() {
        items.push(Box::new(MenuItem::with_id(
            app,
            "recent_header",
            "Recent Notes",
            false,
            None::<&str>,
        )?));
        for head in recents {
            items.push(Box::new(MenuItem::with_id(
                app,
                format!("recent:{}", head.id),
                head.title(),
                true,
                None::<&str>,
            )?));
        }
        items.push(Box::new(PredefinedMenuItem::separator(app)?));
    }

    let new_note = MenuItem::with_id(app, "new_note", "New Note", true, Some("Ctrl+Alt+N"))?;
    let all_notes = MenuItem::with_id(app, "all_notes", "All Notes…", true, None::<&str>)?;
    let help = MenuItem::with_id(app, "help", "Help", true, None::<&str>)?;
    let login_enabled = app.autolaunch().is_enabled().unwrap_or(false);
    let launch_at_login = CheckMenuItem::with_id(
        app,
        "launch_at_login",
        "Launch at Login",
        true,
        login_enabled,
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(app, "quit", "Quit Stick-It", true, None::<&str>)?;

    items.push(Box::new(new_note));
    items.push(Box::new(all_notes));
    items.push(Box::new(PredefinedMenuItem::separator(app)?));
    items.push(Box::new(help));
    items.push(Box::new(launch_at_login));
    items.push(Box::new(PredefinedMenuItem::separator(app)?));
    items.push(Box::new(quit));

    let refs: Vec<&dyn IsMenuItem<Wry>> = items.iter().map(|b| b.as_ref()).collect();
    Menu::with_items(app, &refs)
}

/// Identity of the visible recents list: what would have to change for the menu to look
/// different. Control chars as separators so a note titled like a delimiter can't forge one.
fn recents_fingerprint(recents: &[note_store::NoteHead]) -> String {
    recents
        .iter()
        .map(|h| format!("{}\u{1}{}", h.id, h.title()))
        .collect::<Vec<_>>()
        .join("\u{2}")
}

/// The recents list is only useful if it's current, but rebuilding a native menu on
/// every autosave would churn it several times a second while you type — and on Windows
/// swapping a menu that's open is asking for trouble. So this only swaps when the
/// visible list actually changed (new note, deletion, rename, a reorder).
fn refresh_tray_menu(app: &AppHandle) {
    let recents = note_store::recent_heads(app, RECENT_COUNT);
    let fingerprint = recents_fingerprint(&recents);
    {
        let mut last = LAST_RECENTS.lock().unwrap();
        if *last == fingerprint {
            return;
        }
        *last = fingerprint;
    }
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        match tray_menu(app, &recents) {
            Ok(menu) => {
                let _ = tray.set_menu(Some(menu));
            }
            Err(e) => eprintln!("tray menu rebuild failed: {e}"),
        }
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let recents = note_store::recent_heads(app, RECENT_COUNT);
    *LAST_RECENTS.lock().unwrap() = recents_fingerprint(&recents);

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(Image::from_bytes(TRAY_ICON_BYTES)?)
        .menu(&tray_menu(app, &recents)?)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            id if id.starts_with("recent:") => {
                if let Err(e) = open_note_by_id(app, &id["recent:".len()..]) {
                    eprintln!("opening recent note failed: {e}");
                }
            }
            "new_note" => spawn_new_note(app),
            "all_notes" => show_board_window(app),
            "help" => show_help_window(app),
            "launch_at_login" => {
                let enabled = app.autolaunch().is_enabled().unwrap_or(false);
                let result = if enabled {
                    app.autolaunch().disable()
                } else {
                    app.autolaunch().enable()
                };
                if let Err(e) = result {
                    eprintln!("launch-at-login toggle failed: {e}");
                }
            }
            "quit" => app.exit(0),
            other => println!("tray menu (not yet implemented): {other}"),
        })
        .build(app)?;
    Ok(())
}

/// Routes clicks from the per-note popup menus (color/paper/share/more), all of which
/// funnel through this single app-level handler since Tauri has no per-popup callback
/// — the note/window each item applies to is encoded in its id as "action:value:label"
/// or "action:label".
fn handle_menu_event(app: &AppHandle, id: &str) {
    let mut parts = id.splitn(3, ':');
    match (parts.next(), parts.next(), parts.next()) {
        (Some("color"), Some(color), Some(label)) => {
            if let Some(win) = app.get_webview_window(label) {
                let notes = app.state::<Notes>();
                let saved = with_note(&notes, label, |n| {
                    n.color = color.to_string();
                    n.updated_at = note_store::now_secs();
                    n.clone()
                });
                if let Some(note) = saved {
                    let _ = note_store::save(app, &note);
                    let _ = win.eval(&format!("setColor('{}')", hex_for_color(color)));
                }
            }
        }
        (Some("paper"), Some(paper), Some(label)) => {
            if let Some(win) = app.get_webview_window(label) {
                let notes = app.state::<Notes>();
                let saved = with_note(&notes, label, |n| {
                    n.paper = if paper == "plain" { None } else { Some(paper.to_string()) };
                    n.updated_at = note_store::now_secs();
                    n.clone()
                });
                if let Some(note) = saved {
                    let _ = note_store::save(app, &note);
                    let _ = win.eval(&format!("setPaper('{paper}')"));
                }
            }
        }
        (Some("copy_text"), Some(label), _) => {
            if let Some(note) = app.state::<Notes>().0.lock().unwrap().get(label).cloned() {
                let _ = app.clipboard().write_text(note.text);
            }
        }
        (Some("copy_md"), Some(label), _) => {
            if let Some(note) = app.state::<Notes>().0.lock().unwrap().get(label).cloned() {
                let _ = app.clipboard().write_text(note.md);
            }
        }
        (Some("save_md"), Some(label), _) => {
            if let Some(note) = app.state::<Notes>().0.lock().unwrap().get(label).cloned() {
                let default_name = format!("{}.md", note.title().replace('/', "-"));
                app.dialog()
                    .file()
                    .set_file_name(&default_name)
                    .add_filter("Markdown", &["md"])
                    .save_file(move |picked| {
                        if let Some(path) = picked {
                            if let Ok(p) = path.into_path() {
                                let _ = std::fs::write(p, &note.md);
                            }
                        }
                    });
            }
        }
        (Some("delete_note"), Some(label), _) => {
            let label = label.to_string();
            let app2 = app.clone();
            app.dialog()
                .message("This permanently deletes the note. You can't undo this.")
                .title("Delete this note?")
                .buttons(MessageDialogButtons::OkCancel)
                .show(move |confirmed| {
                    if confirmed {
                        delete_note(&app2, &label);
                    }
                });
        }
        (Some("new_note"), _, _) => spawn_new_note(app),
        (Some("all_notes"), _, _) => show_board_window(app),
        (Some("help"), _, _) => show_help_window(app),
        (Some("quit"), _, _) => app.exit(0),
        _ => {}
    }
}

#[tauri::command]
fn list_notes(app: AppHandle) -> Result<Vec<Note>, String> {
    let dir = note_store::notes_dir(&app);
    let mut result = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if entry.path().extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            if let Ok(data) = std::fs::read_to_string(entry.path()) {
                if let Ok(note) = serde_json::from_str::<Note>(&data) {
                    result.push(note);
                }
            }
        }
    }
    result.sort_by(|a, b| b.updated_at.partial_cmp(&a.updated_at).unwrap());
    Ok(result)
}

/// Mirrors NoteManager.show(): focus the note's window if it's already up, otherwise
/// reopen it from disk. Shared by the board's open button and the tray's recents list.
fn open_note_by_id(app: &AppHandle, id: &str) -> Result<(), String> {
    if let Some(w) = app.get_webview_window(id) {
        return w.set_focus().map_err(|e| e.to_string());
    }
    let path = note_store::notes_dir(app).join(format!("{id}.json"));
    let data = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut note: Note = serde_json::from_str(&data).map_err(|e| e.to_string())?;
    note.open = true;
    note_store::save(app, &note).map_err(|e| e.to_string())?;
    spawn_note_window(app, note).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_note(app: AppHandle, id: String) -> Result<(), String> {
    open_note_by_id(&app, &id)
}

#[tauri::command]
fn delete_note_cmd(app: AppHandle, id: String) -> Result<(), String> {
    delete_note(&app, &id);
    Ok(())
}

#[tauri::command]
fn batch_delete_notes(app: AppHandle, ids: Vec<String>) -> Result<(), String> {
    for id in ids {
        delete_note(&app, &id);
    }
    Ok(())
}

#[tauri::command]
fn board_new_note(app: AppHandle) {
    spawn_new_note(&app);
}

#[tauri::command]
fn board_show_help(app: AppHandle) {
    show_help_window(&app);
}

// Read-only, test-only: lets the E2E suite drop a note file directly on disk (to test
// delete_note_cmd against a note that has no open window, without guessing at Windows'
// AppData path conventions) rather than deleting the one window it's actually attached
// to and losing its own DevTools connection in the process.
#[tauri::command]
fn notes_dir_path(app: AppHandle) -> String {
    note_store::notes_dir(&app).to_string_lossy().into_owned()
}

#[tauri::command]
fn copy_note(app: AppHandle, id: String, markdown: bool) -> Result<(), String> {
    let live = app.state::<Notes>().0.lock().unwrap().get(&id).cloned();
    let note = match live {
        Some(n) => n,
        None => {
            let path = note_store::notes_dir(&app).join(format!("{id}.json"));
            let data = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
            serde_json::from_str(&data).map_err(|e| e.to_string())?
        }
    };
    let text = if markdown { note.md } else { note.text };
    app.clipboard().write_text(text).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .manage(Notes(Mutex::new(HashMap::new())))
        .manage(DragState(Mutex::new(HashMap::new())))
        .manage(ResizeState(Mutex::new(HashMap::new())))
        .manage(PeelState(Mutex::new(HashMap::new())))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state == ShortcutState::Pressed {
                        spawn_new_note(app);
                    }
                })
                .build(),
        )
        .setup(|app| {
            // Sources/StickIt/main.swift's AppDelegate.installEditMenu() already learned
            // this the hard way: with no native menu claiming Cmd+X/C/V/A as a key
            // equivalent, macOS never routes those keystrokes anywhere — the webview's
            // own paste handler would simply never fire. Same fix here.
            let edit_menu = Submenu::with_items(
                app,
                "Edit",
                true,
                &[
                    &PredefinedMenuItem::cut(app, None)?,
                    &PredefinedMenuItem::copy(app, None)?,
                    &PredefinedMenuItem::paste(app, None)?,
                    &PredefinedMenuItem::select_all(app, None)?,
                ],
            )?;
            Menu::with_items(app, &[&edit_menu])?.set_as_app_menu()?;

            app.on_menu_event(|app, event| handle_menu_event(app, event.id().as_ref()));

            build_tray(app.handle())?;

            // ⌥⌘N has no Windows analog and would collide with several macOS system
            // shortcuts here on the dev machine anyway — Ctrl+Alt+N everywhere, matching
            // the Windows scoping plan's chosen default.
            let shortcut = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyN);
            app.global_shortcut().register(shortcut)?;

            restore_open_notes(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            save,
            win,
            peel,
            ui,
            list_notes,
            open_note,
            delete_note_cmd,
            batch_delete_notes,
            copy_note,
            board_new_note,
            board_show_help,
            notes_dir_path
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

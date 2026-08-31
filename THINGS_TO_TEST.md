# Things to test — Note Groups + Hide This Note

Uncommitted feature in `BoardWindow.swift`/`NoteWindow.swift`/`NoteStore.swift`. Covers
the All Notes board's new grouping (folders) and the new "Hide This Note" action.

## Note Groups

- Select mode → select a few notes → "Group…" → type a name → they should disappear
  from the top-level grid and a folder card should appear in their place
- Click a folder card → see only that group's notes, breadcrumb reads
  `All Notes / <name>`
- Click "All Notes" in the breadcrumb → back to the top level
- Drag a single note (not in select mode) onto a folder card → it joins that group
- While inside a folder, drag a note onto the breadcrumb row → it leaves the group
- Note card's right-click menu → "Remove from '<group>'" → same effect as the drag
- Search (top bar) while at the top level → folder cards disappear, results include
  notes from *every* group, not just ungrouped ones
- Group badge shows on a card only when it's visible outside its own folder (i.e. via
  search) — should NOT show while browsing inside that same folder
- Delete every note in a group → the folder card should vanish on its own (no orphan
  empty folder) — group membership isn't a separate stored entity, it only exists as
  long as some note still points at it
- Regroup/select-mode-group notes that are already in *different* existing groups —
  batch "Group…" prompt's default text should reflect that ambiguity sensibly (blank,
  not one of the conflicting names)
- Drag a note onto the *same* folder card it's already in — should no-op harmlessly
- While inside a folder, scroll down past many notes, then drag one toward the top
  edge — the grid should auto-scroll back up to reveal the folder cards/breadcrumb
- Rename a group via Select → Group… with a new name on already-grouped notes —
  old folder should disappear if now empty, new one should appear

## Hide This Note

- Note's "…" menu → "Hide This Note" → window closes, note still shows in All Notes
  (not deleted)
- Reopen it from All Notes → confirm content, color, paper, pin, group all intact
- Confirm this is truly identical to clicking the ✕ button (same note ends up in the
  same state either way)
- Help window → "⋯ More" row should now mention hiding, not just deleting

## Cross-cutting

- Quit and relaunch the app → groups, and any hidden notes, persist correctly
- A note saved *before* this update (no `group` key in its JSON on disk) should still
  load without error — `group` is `nil`-safe by design, but worth confirming an old
  note file actually opens clean

## Undo Text Edits (⌘Z)

- Type into a note, then ⌘Z → the typed text disappears (standard text-undo, same as
  any editor); ⇧⌘Z (redo) brings it back
- Apply formatting (bold, bullet list, heading via `#` + space) → ⌘Z reverts just that
  formatting action
- Paste content into a note → ⌘Z removes the paste
- Two notes open at once: edit both, ⌘Z in note A → only note A's edit reverts, note B
  is untouched (each note's WKWebView has its own independent undo stack)
- Deleting a whole note (from its "…" menu, or the board) is still permanent — ⌘Z does
  *not* bring back a deleted note, only in-progress edits within a still-open note

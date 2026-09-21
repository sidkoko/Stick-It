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

## Drag-to-Select (marquee)

This is the part I can't verify myself in this environment (no way to drive/screenshot
the GUI) — the main real risk is gesture arbitration between the new marquee drag and
the existing per-note drag-to-group gesture, so this needs an actual pass.

- Click-drag starting on **empty space** between/around cards → a selection rectangle
  should appear and grow with the drag; Select mode should turn on automatically
  (toolbar switches to the selected-count/Group/Delete/Cancel row) even if you never
  clicked "Select" first
- Release the drag → every card the rectangle touched (even partially) should be
  checked/selected
- Start a fresh (non-shift) drag elsewhere → previous selection should be replaced, not
  added to
- Hold **⇧** while dragging → new cards should be added to whatever was already selected
  instead of replacing it
- Start the drag *on top of a note card* (not empty space) → should NOT start a marquee;
  it should still behave like today (single click selects/opens; drag onto a folder card
  still groups it) — this is the one most likely to misbehave, check it carefully
- Same check starting the drag *on top of a folder card* → shouldn't start a marquee,
  and the folder card's own click-to-open should still work normally
- Drag a marquee across a mix of note cards and a folder card → only the notes get
  selected, the folder card is never included in the selected count
- Try this both inside a folder (activeGroup set) and at the top level

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

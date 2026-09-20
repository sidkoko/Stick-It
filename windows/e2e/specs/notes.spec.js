// Covers the actual value prop end to end: type into a note, it persists through the
// real Rust/file-store backend, and deletion removes it from the store. Known gaps,
// confirmed rather than assumed — each cost a real CI cycle to establish:
//   - Deletion normally goes through a native `confirm()` dialog. Tests call
//     `delete_note_cmd` directly instead of clicking Delete, which still proves the
//     backend command works, just not the confirm-dialog step itself.
//   - The All Notes board (a second native window) isn't covered: switching to it via
//     WebDriver never actually lands there (board.html never shows up in location.href,
//     even polled for 10s). Looks like a real tauri-driver/WebView2 multi-window
//     limitation, not anything fixable from this app's code.
//   - Creating a SECOND note window via the app itself (spawn_note_window: transparent,
//     undecorated, custom drag-drop) hangs the whole WebDriver session indefinitely —
//     even 150s wasn't enough, and every later command timed out too. The board window
//     (plain, no transparency) creates fine by comparison. This looks like WebView2
//     struggling to composite a fully transparent/layered window without real GPU
//     acceleration on this CI VM — plausibly a non-issue on real end-user hardware, but a
//     real wall for testing it here. The delete test below sidesteps it by injecting a
//     second note via the filesystem instead of a real window.
const fs = require('fs')
const path = require('path')

const invoke = (name, args) => browser.execute(
  (n, a) => window.__TAURI__.core.invoke(n, a || {}),
  name,
  args,
)

describe('Stick-It for Windows', () => {
  it('launches with a single blank note', async () => {
    const handles = await browser.getWindowHandles()
    expect(handles).toHaveLength(1)
    const editor = await $('#editor')
    expect(await editor.getText()).toBe('')
  })

  it('persists typed text through the real backend', async () => {
    const editor = await $('#editor')
    await editor.click()
    await browser.keys('Hello from the E2E suite')
    await browser.pause(600) // scheduleSave() in editor.html debounces 350ms

    const notes = await invoke('list_notes')
    expect(notes).toHaveLength(1)
    expect(notes[0].text).toBe('Hello from the E2E suite')
  })

  it('deletes a note through the backend command', async () => {
    // Injected via the filesystem, not a real window: creating a second note window
    // is the thing that hangs the whole session (see above), and deleting the ONE
    // note whose window WE'RE attached to would destroy WebDriver's own DevTools
    // connection along with it. A file-only note has no window for delete_note_cmd
    // to destroy, so this exercises the real delete command without touching either
    // problem — notes_dir_path/list_notes both read straight from disk either way.
    const dir = await invoke('notes_dir_path')
    const injected = {
      id: 'e2e-injected-note', name: null, paper: null, drawing: null,
      html: '', text: 'injected for delete test', md: '', images: [],
      color: 'yellow', x: 0, y: 0, w: 300, h: 280,
      pinned: true, collapsed: false, open: false,
      createdAt: Date.now() / 1000, updatedAt: Date.now() / 1000,
    }
    fs.writeFileSync(path.join(dir, `${injected.id}.json`), JSON.stringify(injected))

    await browser.waitUntil(async () => (await invoke('list_notes')).length === 2, {
      timeoutMsg: 'expected the injected note to show up via list_notes',
    })

    await invoke('delete_note_cmd', { id: injected.id })

    const remaining = await invoke('list_notes')
    expect(remaining).toHaveLength(1)
    expect(remaining.find(n => n.id === injected.id)).toBeUndefined()
  })
})

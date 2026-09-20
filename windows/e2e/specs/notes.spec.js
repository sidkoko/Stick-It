// Covers the actual value prop end to end: type into a note, it persists through the
// real Rust/file-store backend, and the All Notes board reflects it. Two known gaps,
// both because the app uses native OS chrome the WebView2 WebDriver session can't reach:
//   - Deletion normally goes through a native `confirm()` dialog. Tests call
//     `delete_note_cmd`/`batch_delete_notes` directly instead of clicking Delete, which
//     still proves the backend command works, just not the confirm-dialog step itself.
//   - "All Notes" is normally opened from a native tray/note menu. The board_show_board
//     command (main.rs) exists solely so this suite has a way in.
const invoke = (name, args) => browser.execute(
  (n, a) => window.__TAURI__.core.invoke(n, a || {}),
  name,
  args,
)

// execute() auto-awaits a script's returned Promise before responding — which is what
// `invoke` above wants for data commands. But commands that create/destroy a native
// window (board_show_board, delete_note_cmd, batch_delete_notes) hang the whole
// WebDriver session that way: window-lifecycle operations appear to block the message
// pump the CDP connection needs to report the promise settling at all. Fire those
// without waiting on their promise, and confirm the resulting state by polling instead.
const invokeNoWait = (name, args) => browser.execute(
  (n, a) => { window.__TAURI__.core.invoke(n, a || {}) },
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

  it('shows the note on the All Notes board and can create another', async () => {
    const before = await browser.getWindowHandles()
    await invokeNoWait('board_show_board')
    await browser.waitUntil(async () => (await browser.getWindowHandles()).length === 2, {
      timeoutMsg: 'expected the board window to open',
    })
    // switchWindow(urlOrTitle) doesn't reliably match across separate native Tauri
    // windows (it comes back empty-handed even once the window genuinely exists) —
    // diffing the handle list before/after is the one thing that's actually reliable.
    const after = await browser.getWindowHandles()
    const boardHandle = after.find(h => !before.includes(h))
    await browser.switchToWindow(boardHandle)

    // The window handle shows up before board.html has actually finished navigating —
    // switching to it immediately lands on a still-blank document (empty title, no
    // window.__TAURI__ yet). Poll for real readiness instead of assuming it's instant.
    await browser.waitUntil(async () => (await browser.execute(() => document.title)) === 'All Notes', {
      timeoutMsg: 'expected the new window to finish navigating to board.html',
    })

    await browser.waitUntil(async () => (await $$('#cards > *')).length === 1, {
      timeoutMsg: 'expected one card on the board',
    })
    expect(await $('#cards').getText()).toContain('Hello from the E2E suite')

    await $('#newNoteBtn').click()
    await browser.waitUntil(async () => (await invoke('list_notes')).length === 2, {
      timeoutMsg: 'New Note button should create a second note',
    })
  })

  it('deletes a note through the backend command', async () => {
    const notes = await invoke('list_notes')
    await invokeNoWait('delete_note_cmd', { id: notes[0].id })

    await browser.waitUntil(async () => (await invoke('list_notes')).length === 1, {
      timeoutMsg: 'expected one note left after the delete',
    })
    const remaining = await invoke('list_notes')
    expect(remaining.find(n => n.id === notes[0].id)).toBeUndefined()

    await browser.execute(() => window.load())
    await browser.waitUntil(async () => (await $$('#cards > *')).length === 1, {
      timeoutMsg: 'board should drop to one card after the delete',
    })
  })
})

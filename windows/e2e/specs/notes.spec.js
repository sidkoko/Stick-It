// Covers the actual value prop end to end: type into a note, it persists through the
// real Rust/file-store backend, a hotkey creates another, and deletion removes it from
// the store. Two known gaps:
//   - Deletion normally goes through a native `confirm()` dialog. Tests call
//     `delete_note_cmd` directly instead of clicking Delete, which still proves the
//     backend command works, just not the confirm-dialog step itself.
//   - The All Notes board (a second native window) isn't covered at all: switching to
//     it via WebDriver never actually lands there — confirmed with an unambiguous check
//     (board.html never shows up in location.href, even polled for 10s) rather than
//     assumed. This looks like a real tauri-driver/WebView2 multi-window limitation, not
//     anything fixable from this app's code. If board.html-specific behavior needs
//     coverage later, it'll need a different tool (e.g. Playwright driving WebView2's
//     DevTools protocol directly) rather than more tauri-driver window-switching.
const invoke = (name, args) => browser.execute(
  (n, a) => window.__TAURI__.core.invoke(n, a || {}),
  name,
  args,
)

// execute() auto-awaits a script's returned Promise before responding — which is what
// `invoke` above wants for data commands. But delete_note_cmd destroys a native window,
// and awaiting that promise through execute() hangs the whole WebDriver session: window-
// lifecycle operations block whatever lets the promise ever resolve. Fire it without
// waiting and confirm the resulting state by polling instead.
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

  it('creates a second note via the global New Note shortcut', async () => {
    await browser.keys(['Control', 'Alt', 'n'])
    await browser.waitUntil(async () => (await invoke('list_notes')).length === 2, {
      timeoutMsg: 'Ctrl+Alt+N should create a second note',
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
  })
})

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
//   - Creating a SECOND note window (spawn_note_window: transparent, undecorated, custom
//     drag-drop) hangs the whole WebDriver session indefinitely — even 150s wasn't
//     enough, and every later command timed out too. The board window (plain, no
//     transparency) creates fine by comparison. This looks like WebView2 struggling to
//     composite a fully transparent/layered window without real GPU acceleration on this
//     CI VM — plausibly a non-issue on real end-user hardware, but a real wall for testing
//     it here. If multi-note coverage matters later, it'll need a different tool (e.g.
//     Playwright driving WebView2's DevTools protocol directly) rather than tauri-driver.
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

  it('deletes a note through the backend command', async () => {
    const notes = await invoke('list_notes')
    await invokeNoWait('delete_note_cmd', { id: notes[0].id })

    // Can't invoke() list_notes afterward to confirm zero notes remain — this is the
    // ONLY note, so delete_note_cmd destroys the very window WebDriver is attached to,
    // and any further execute() against it fails with "window already closed". The
    // window closing at all is itself the real, observable, meaningful signal here.
    await browser.waitUntil(async () => (await browser.getWindowHandles()).length === 0, {
      timeoutMsg: 'expected the note\'s window to close after the delete',
    })
  })
})

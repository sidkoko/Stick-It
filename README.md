# Stick-It 📝

A native macOS sticky notes app, built because Apple's Stickies wasn't cutting it. Every note is a real, borderless floating window styled to actually look and feel like paper — no hidden menus, no guessing what to click next.

## Features

- **Paper that looks like paper** — shaded like a real sticky note, with a curled corner and a fold crease along the bottom edge
- **Tear-off pages** — pull the curled corner and peel a fresh note off the pad, revealing it underneath as you go, just like a real notepad
- **Rich formatting** — bold/italic/underline, fonts, sizes, text colors, headings
- **Checklists & bullets** — real clickable checkboxes, or type `- ` / `[] ` / `# ` for instant markdown-style shortcuts
- **Drawing** — a pencil tool with pen colors and an eraser, sketch right on the note
- **Paper styles** — plain, lined, or grid
- **Pin** — keep a note floating above every window, on every desktop & Space
- **Global hotkey** — ⌥⌘N from anywhere spawns a new note under your cursor
- **All Notes board** — searchable grid of every note, with single or batch delete
- **Autosave** — everything, always, including window position — no save button, nothing lost on quit/restart
- **Launch at Login**

## Download

1. Grab **`Stick-It.app.zip`** from [Releases](../../releases). Ignore the "Source code (zip)" / "Source code (tar.gz)" links below it — those are just raw code, not the app.
2. Unzip it, then drag `Stick-It.app` into your **Applications** folder.
3. Open it. macOS will block it and say it can't verify the developer — that's expected, this app isn't in the App Store (yet). Click **Done**.
4. Go to **System Settings → Privacy & Security**, then scroll all the way to the bottom.
5. You'll see: *"Stick-It" was blocked to protect your Mac.* Click **Open Anyway**, then confirm with your password or Touch ID.

That's it — Stick-It opens, and every launch after this is instant, no more warnings. ([Same steps, as a webpage →](https://claude.ai/code/artifact/0f0214ff-8904-4aa5-a158-0fab4f0fe7f5))

## Building from source

Requires macOS 14+ and Swift 5.9+ (ships with Xcode / Command Line Tools).

```sh
git clone https://github.com/sidkoko/Stick-It.git
cd Stick-It
./build.sh --run
```

This builds `Stick-It.app` into `build/` and launches it. Re-run `./build.sh --run` any time to rebuild.

## License

MIT — see [LICENSE](LICENSE).

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

Grab the latest **`Stick-It.app.zip`** from [Releases](../../releases) — that's the one to pick; ignore the "Source code (zip/tar.gz)" links GitHub adds automatically, those are just the raw code, not the app.

Unzip it, then double-click **`Open Stick-It.command`** sitting next to the app — it installs Stick-It to Applications, clears the macOS "unidentified developer" warning, and opens it, all in one click. (This isn't notarized, since that requires a paid Apple Developer account, so macOS would otherwise flag it the first time you open it — that's all this script is for.) If that file itself shows a warning, right-click it and choose **Open** instead.

Prefer to do it manually? [Step-by-step guide →](https://claude.ai/code/artifact/0f0214ff-8904-4aa5-a158-0fab4f0fe7f5)

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

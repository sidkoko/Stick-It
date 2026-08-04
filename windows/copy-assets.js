// Keeps editor.html/help.html as one shared source of truth (see the Windows
// scoping plan) — this just copies the macOS resources verbatim into dist/,
// no per-platform forking.
const fs = require('fs');
const path = require('path');

const macosSrc = path.join(__dirname, '..', 'Sources', 'StickIt', 'Resources');
const winSrc = path.join(__dirname, 'src-frontend');
const dist = path.join(__dirname, 'dist');

fs.mkdirSync(dist, { recursive: true });
for (const name of ['editor.html', 'help.html']) {
  fs.copyFileSync(path.join(macosSrc, name), path.join(dist, name));
}
// board.html has no macOS equivalent (that side uses native SwiftUI) — it's a
// Windows-only page, tracked under src-frontend/ instead of being copied in.
for (const name of ['board.html']) {
  fs.copyFileSync(path.join(winSrc, name), path.join(dist, name));
}
console.log('copied editor.html + help.html + board.html into windows/dist');

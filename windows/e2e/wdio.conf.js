// WebDriverIO + tauri-driver config for the Windows app's E2E suite. Windows-only —
// tauri-driver wraps msedgedriver, which only exists on Windows — so this can't run on
// this Mac; it's meant for the `windows-e2e.yml` CI job on a real windows-latest runner.
// Pinned to wdio v7: newer major versions have had typing/compat issues with tauri-driver
// (see https://github.com/Haprog/tauri-wdio-win-test), and this suite is plain JS anyway.
const os = require('os')
const path = require('path')
const { spawn, spawnSync } = require('child_process')

let tauriDriver

exports.config = {
  runner: 'local',
  // Must be __dirname-relative, not CWD-relative: `npm run test:e2e` invokes `wdio` from
  // windows/, but this config lives in windows/e2e/ — a plain './specs/...' resolves
  // against the wrong directory and silently matches zero files.
  specs: [path.join(__dirname, 'specs/**/*.spec.js')],
  maxInstances: 1,
  capabilities: [
    {
      maxInstances: 1,
      'tauri:options': {
        application: path.resolve(__dirname, '../src-tauri/target/release/stickit-windows.exe'),
      },
    },
  ],
  logLevel: 'info',
  bail: 0,
  waitforTimeout: 10000,
  connectionRetryTimeout: 120000,
  connectionRetryCount: 3,
  framework: 'mocha',
  reporters: ['spec'],
  // Bumped from 60s while diagnosing: note windows are created transparent+undecorated
  // with a custom drag-drop override (unlike the plain board window), and constructing a
  // layered/transparent window is known to be much slower without real GPU compositing —
  // plausible on a CI VM. This tests "just slow" vs "actually stuck" cheaply.
  mochaOpts: { ui: 'bdd', timeout: 150000 },

  // The CI job builds release separately (so a build failure shows up as its own step,
  // not buried in a wdio log), but this keeps `npm run test:e2e` self-sufficient locally
  // on a real Windows box too.
  onPrepare: () => spawnSync('cargo', ['build', '--release'], {
    cwd: path.resolve(__dirname, '../src-tauri'),
    stdio: 'inherit',
  }),

  beforeSession: () => {
    tauriDriver = spawn(
      path.resolve(os.homedir(), '.cargo', 'bin', 'tauri-driver'),
      [],
      { stdio: [null, process.stdout, process.stderr] },
    )
  },

  afterSession: () => tauriDriver && tauriDriver.kill(),
}

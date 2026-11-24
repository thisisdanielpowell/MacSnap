// build.js
// Builds WindowSnap.app from Sources/ with Xcode's Swift compiler:
// runs the layout tests (Tests/), compiles in strict Swift 6 mode with warnings as errors, bundles with
// Info.plist, signs ad-hoc with Hardened Runtime, verifies the signature, and installs to ~/Applications.
// Run: node build.js
// Without Xcode: node build.js --clt  (Apple's Command Line Tools)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = __dirname;
const sourcesDir = path.join(root, 'Sources');
const appDir = path.join(root, 'build', 'WindowSnap.app');
const macosDir = path.join(appDir, 'Contents', 'MacOS');
const useCommandLineTools = process.argv.includes('--clt');
const developerDir = useCommandLineTools
  ? '/Library/Developer/CommandLineTools'
  : '/Applications/Xcode.app/Contents/Developer';

if (!fs.existsSync(developerDir)) {
  console.error(useCommandLineTools
    ? 'Command Line Tools not found. Install them with xcode-select --install.'
    : 'Xcode not found at /Applications/Xcode.app. Install it from the App Store, or build with --clt.');
  process.exit(1);
}
console.log(`Toolchain: ${useCommandLineTools ? 'Command Line Tools' : 'Xcode'} (${developerDir})`);
// DEVELOPER_DIR points xcrun at the chosen tools for this build only; the Mac's xcode-select setting is unchanged.
const env = { ...process.env, DEVELOPER_DIR: developerDir };

/**
 * Runs a command with fixed arguments (no shell), prints its output, and stops the build on failure.
 * @param {string} cmd - The program to run.
 * @param {string[]} args - Its arguments.
 */
function run(cmd, args) {
  const result = spawnSync(cmd, args, { encoding: 'utf8', env });
  const output = ((result.stdout || '') + (result.stderr || '')).trim();
  if (output) console.log(output);
  if (result.status !== 0) {
    console.error(`FAILED: ${cmd} (exit ${result.status})`);
    process.exit(1);
  }
}

const sources = fs.readdirSync(sourcesDir)
  .filter((name) => name.endsWith('.swift'))
  .sort()
  .map((name) => path.join(sourcesDir, name));

run('xcrun', ['--find', 'swiftc']);

// 1. Layout tests: compile the geometry code with Tests/LayoutTests.swift and run it. Any failure stops the build.
const testBinary = path.join(root, 'build', 'tests', 'LayoutTests');
fs.mkdirSync(path.dirname(testBinary), { recursive: true });
run('xcrun', ['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
  path.join(sourcesDir, 'SnapLayout.swift'), path.join(root, 'Tests', 'LayoutTests.swift'), '-o', testBinary]);
run(testBinary, []);

// 2. The app.
fs.rmSync(appDir, { recursive: true, force: true });
fs.mkdirSync(macosDir, { recursive: true });
fs.copyFileSync(path.join(root, 'Info.plist'), path.join(appDir, 'Contents', 'Info.plist'));

run('xcrun', ['swiftc', '-O', '-swift-version', '6', '-warnings-as-errors', ...sources,
  '-o', path.join(macosDir, 'WindowSnap'), '-framework', 'Cocoa', '-framework', 'Carbon', '-framework', 'ServiceManagement']);
run('codesign', ['--force', '--options', 'runtime', '--sign', '-', appDir]);
run('codesign', ['--verify', '--strict', '--verbose=2', appDir]);
console.log(`Built ${appDir}`);

// 3. Install to ~/Applications, a stable place for the Accessibility entry and the login item.
//    ditto copies the bundle exactly, signature included. The build copy is then deleted, so there is
//    only ever one WindowSnap.app (two copies would show up twice in Accessibility and Spotlight).
const installDir = path.join(process.env.HOME, 'Applications');
const installedApp = path.join(installDir, 'WindowSnap.app');
fs.mkdirSync(installDir, { recursive: true });
fs.rmSync(installedApp, { recursive: true, force: true });
run('ditto', [appDir, installedApp]);
run('codesign', ['--verify', '--strict', installedApp]);
fs.rmSync(appDir, { recursive: true, force: true });
console.log(`Installed ${installedApp}`);

# WindowSnap

A small macOS menu bar app that snaps the frontmost window to halves, thirds, corners, the center, or a 16:9 size, moves it between displays, arranges 2 to 4 windows side by side, and switches between open windows and their tabs, all from the keyboard.

Built with Swift and Apple frameworks only. No third-party code, no network access, no stored data.

## Shortcuts

### Snapping

Snapping uses Control+Option, so WindowSnap leaves the fn/Globe key, plain Control shortcuts, and macOS's own window tiling shortcuts alone.

| Shortcut | What it does |
|---|---|
| Ctrl+Option+Left | Left side. Press again for 2/3, then 1/3 of the screen |
| Ctrl+Option+Right | Right side. Press again for 2/3, then 1/3 of the screen |
| Ctrl+Option+Up | Top half |
| Ctrl+Option+Down | Bottom half |
| Ctrl+Option+U | Top-left quarter |
| Ctrl+Option+I | Top-right quarter |
| Ctrl+Option+J | Bottom-left quarter |
| Ctrl+Option+K | Bottom-right quarter |
| Ctrl+Option+C | Center the window, keeping its size |
| Ctrl+Option+F | Centered 16:9 window, up to 85% of the screen |
| Ctrl+Option+M | Move the window to the next display |

Snapped windows (sides, halves, corners) leave an 8-point gap at the screen edges and between neighboring windows. Center keeps at least that gap from the edges. To change it, edit `gap` in `Sources/SnapLayout.swift` and rebuild.

After every snap and arrangement, an orange outline flashes around where each window actually landed, then fades out (about 0.7 seconds). Its corners follow the window's, with Apple's continuous corner curve; macOS doesn't share its exact window corner radius, so `windowCornerRadius` (16) is an approximation. Change the color, width, roundness, or timing at the top of `Sources/SnapHighlight.swift`.

### Arrange windows

| Keys | What it does |
|---|---|
| Ctrl+Option+R | Opens the arrange picker |
| Up / Down arrows | Move the highlight |
| Space | Pick or un-pick the highlighted window (2 to 4; the pick number shows on the right) |
| Return | Arrange the picked windows, in pick order |
| Esc, or click outside | Close without arranging |
| Ctrl+Option+R again within 3 seconds | Move the same windows to the next layout |

| Windows | Layouts, in cycling order |
|---|---|
| 2 | Halves, then 2/3 + 1/3, then 1/3 + 2/3 |
| 3 | Big left + two stacked right, then three columns |
| 4 | Four corners, then big left + three stacked right |

Arranged windows use the same gaps as snapping, on the screen of the first picked window. To add or change layouts, edit `arrangements` in `Sources/SnapLayout.swift`; to change the cycle time, edit `cycleSeconds` in `Sources/ArrangeController.swift`.

### Window switcher

| Keys | What it does |
|---|---|
| Option+Tab | Opens the switcher on the previous window. Keep holding Option and press Tab to move down |
| Option+Shift+Tab | Opens the switcher on the last window, or moves up while it's open |
| Release Option | Switches to the highlighted window or tab |
| Up / Down arrows | Move the highlight |
| Right arrow | Show the highlighted window's tabs under it (beeps if the app doesn't expose tabs) |
| Left arrow | Hide them again |
| Return | Switches to the highlighted window or tab |
| Q | Asks the highlighted line's app to quit (the app can still ask to save) |
| Esc, or click outside | Closes without switching |
| Option+S | Opens the switcher in search mode: type part of a window title, tab title, or app name, then Return |

The switcher lists standard windows of regular apps, most recently used app first, with each app's icon, the window title, and the app name. Minimized windows are listed (including ones an app doesn't mark as standard, like Outlook's) and come back when chosen.

Apps with no window on the current desktop show as one line, "No windows on this desktop", the way Cmd+Tab lists apps. That covers apps whose windows are all on another desktop (Space) or in full screen, apps whose only window is minimized but not reported, and apps with no windows open. macOS's Accessibility API lists only the current desktop's windows, and titles of other windows would need Screen Recording, so those windows can't be listed one by one. Choosing the line works like clicking the app's Dock icon: macOS asks the running app to reopen, which in most apps restores a minimized window, moves to the desktop where its windows are, or opens a new window if it has none. Finder may not switch desktops this way, because Finder also owns the desktop itself on every Space; use Mission Control for Finder windows on another desktop. An app with windows on both this desktop and another shows only this desktop's windows.

Tabs work in any app that exposes a standard tab bar through the Accessibility API. Tested working: Chrome, Edge. Not working: Obsidian, which draws its own tabs. Search lists every matching tab under its window. To keep search fast, the tab search skips the parts of a window that never hold a tab bar (web page content, file lists, tables, text areas) and reads each element in one batched request.

The panel is a frosted background with a tint on top for readability; change `backgroundOpacity` in `Sources/SwitcherPanel.swift` (0 is only the blur, 1 is fully opaque).

### Menu

The menu bar icon (a 2x2 grid) lists the shortcuts, shows whether the Accessibility permission is on, and has Quit. A shortcut macOS refused to register is marked "(could not register)". macOS may still accept a combination another app also uses, so a clash with another app's shortcut is possible; change the shortcut in `Sources/AppDelegate.swift` if one happens.

## Requirements

- Built and tested on macOS 26 (Tahoe). Older versions are untested
- Xcode (from the App Store), or Apple's Command Line Tools with `--clt` (`xcode-select --install`)
- Node.js, only to run the build script

## Build and run

```
node build.js
open ~/Applications/WindowSnap.app
```

`build.js` does four things, and stops at the first failure:

1. Runs the layout tests (`Tests/LayoutTests.swift`, see Tests)
2. Compiles everything in `Sources/` with Xcode's Swift compiler in strict Swift 6 mode with warnings treated as errors, and bundles it with `Info.plist`
3. Signs it ad-hoc with Hardened Runtime and verifies the signature
4. Installs it to `~/Applications/WindowSnap.app`, a stable place for the Accessibility entry and the login item, and deletes the build copy so there's only ever one WindowSnap.app

It stops if Xcode isn't installed; `node build.js --clt` builds with the Command Line Tools instead. Neither changes the Mac's `xcode-select` setting.

On first launch, macOS asks for the Accessibility permission: System Settings > Privacy & Security > Accessibility, turn on WindowSnap. After every rebuild, turning it off and on is not enough, because the list entry still points to the old build's signature (see Security). Instead: select WindowSnap, click the minus button to remove it, then add it back (plus button, or reopen WindowSnap and allow it when asked). If the minus button won't remove it, clear WindowSnap's entry from Terminal with `tccutil reset Accessibility local.windowsnap.app` (affects only WindowSnap), then reopen it and allow it. Restarting the Mac or reopening the app keeps the permission.

To start WindowSnap when you log in, choose **Open at Login** in its menu (a checkmark shows when it's on). It uses Apple's login item API (`SMAppService`) and also appears in System Settings > General > Login Items, where it can be turned off.

## Tests

`Tests/LayoutTests.swift` checks the window geometry in `Sources/SnapLayout.swift` (131 checks): the 8-point gap at every screen edge and between neighboring windows, side widths and cycling, center, the exact 16:9 ratio, moving to another display, and every arrange layout (one frame per window, exact gaps, no overlaps). It's pure math, so it needs no permissions and moves no windows. `build.js` runs it before every build.

The expected gap is written out in the test (8), not read from `SnapLayout.gap`, so an accidental change fails the build. If you change the gap on purpose, change it in both places.

The tests cover the math only. Moving real windows, the switcher, tabs, and hotkeys depend on macOS and other apps, so they're checked by hand.

## How it works

| File | Purpose |
|---|---|
| `Sources/main.swift` | Entry point. Starts the app as a menu bar app (no Dock icon, no window) |
| `Sources/AppDelegate.swift` | Defines the shortcuts, registers them, sends each one to snapping, the switcher, or arrange, builds the menu (including Open at Login), and asks for the Accessibility permission |
| `Sources/HotkeyCenter.swift` | Registers the shortcuts with macOS (Carbon `RegisterEventHotKey`) and passes each press on as a command |
| `Sources/WindowMover.swift` | Reads and sets window position and size (one window for snapping, several for arranging), switches an app's "enhanced user interface" setting off for the moment of a move where another program has it on (see Limitations), and finds the window's screen |
| `Sources/SnapLayout.swift` | Pure geometry: the target frame for each snap and each multi-window layout, including gaps. No system calls, no state |
| `Sources/WindowCatalog.swift` | The window list shared by the switcher and arrange (most recent app first), reading a window's tabs, and bringing a window or tab forward or quitting its app |
| `Sources/SwitcherController.swift` | The switcher's behavior: opening, moving the highlight, showing tabs, search over windows and tabs, Option release, Return, Q, Esc |
| `Sources/ArrangeController.swift` | The arrange picker's behavior: picking 2 to 4 windows, arranging them, and cycling layouts |
| `Sources/SwitcherPanel.swift` | The panel the switcher and arrange share: hint line, search field, and rows for windows and tabs. Drawing only |
| `Sources/SnapHighlight.swift` | The orange outline flashed after a snap or arrangement: a see-through, click-through window of WindowSnap's own |
| `Sources/AX.swift` | Type-checked Accessibility reads shared by snapping and the switcher |
| `Tests/LayoutTests.swift` | Layout tests for `SnapLayout.swift`, run by `build.js` before every build |
| `Info.plist` | App bundle settings: bundle ID, menu bar only (`LSUIElement`) |
| `build.js` | Test, build, sign, verify, and install |

## Security

What WindowSnap can do, and what limits it.

| Question | Answer |
|---|---|
| What permissions does it need? | Only Accessibility, to move, resize, list, and raise windows. No Input Monitoring, Screen Recording, Full Disk Access, camera, microphone, or admin rights. It runs as the signed-in user |
| Can it see what I type? | Not in other apps. It registers its shortcuts with macOS (`RegisterEventHotKey`), and macOS delivers only those exact key combinations, as a numeric ID. It has no event tap and no global or local key monitor. While the switcher or arrange picker is open and focused, keys go to it the same way they go to any app you type in; that stops when it closes |
| How does it notice Option being released? | It checks which modifier keys are held (`NSEvent.modifierFlags`: Shift, Control, Option, Command) while the switcher is open. That reveals no letters or other keys |
| What can it see and change? | Snapping and arranging: window position and size. Where another program has switched on an app's "enhanced user interface" setting, they also switch it off for that app for the moment of the move and straight back on (see Limitations). Switcher and arrange: the list of windows on the current desktop and their titles, and tab titles when you expand a window or search. They can raise or un-minimize a window; the switcher can press a tab's button when you choose that tab (the same as clicking the tab), reopen an already-running app the way clicking its Dock icon does (`NSWorkspace.openApplication`, never a second copy, never an app that isn't running), and ask an app to quit. It doesn't read the window server's window list, window contents, or any screen image, and doesn't type or click anything else |
| Window and tab titles can be sensitive. Are they kept? | No. The lists and any search text exist only while a panel is open and are dropped when it closes. Tabs are read only when you expand a window or search. For the 3-second layout cycle, arrange keeps only references to the arranged windows and their apps, no titles, then drops them. Nothing is saved or sent |
| Does it send or store data? | No. The app has no network, file write, saved settings, keychain, clipboard, or command-launch calls. The only app it opens is one that's already running, to bring it forward like a Dock click |
| What is the orange outline? | WindowSnap's own transparent window, drawn around the moved window's frame. Clicks pass through it, it never takes focus, and it doesn't capture or read the screen or the other app |
| What libraries does it use? | Apple system frameworks only (AppKit, ApplicationServices, Carbon, CoreGraphics, Foundation, QuartzCore for the highlight's rounded corners, ServiceManagement for Open at Login) and the Swift runtime |
| Does Open at Login add anything? | It registers WindowSnap with Apple's login item API (`SMAppService.mainApp`), which needs no extra permission and is listed in System Settings > General > Login Items. No launch agent file, no background helper, no admin rights |
| How is it signed? | Ad-hoc, with Hardened Runtime, which blocks other processes from injecting code into it. No entitlements. If the app file is replaced or changed, the signature no longer matches and macOS drops its Accessibility permission, so a tampered copy can't use it |
| Why not a Developer ID? | It's built and run locally. A Developer ID and notarization matter for apps that are downloaded or shared |

To check these claims yourself on a build:

```
# Libraries: all should be under /System/Library or /usr/lib
otool -L build/WindowSnap.app/Contents/MacOS/WindowSnap

# C functions it calls (look for event taps, sockets, file writes)
nm -u build/WindowSnap.app/Contents/MacOS/WindowSnap

# Objective-C methods aren't listed by nm; search the binary for their names instead
strings build/WindowSnap.app/Contents/MacOS/WindowSnap | grep -E 'addGlobalMonitor|addLocalMonitor|SCStream|NSURLSession|NSUserDefaults|NSTask'

# Signature flags (expect adhoc,runtime) and entitlements (expect none)
codesign -dv --entitlements - build/WindowSnap.app
```

`NSPasteboard` appears in the binary only inside the method list of Apple's `NSWindowDelegate` protocol, which the switcher and arrange picker adopt to close when you click outside them, and `openURL`/`openURLs` only inside Apple's `NSApplicationDelegate` method list. WindowSnap never calls the clipboard or opens URLs. `nm` also lists Swift's `URL` bridging functions; those convert the app's own bundle path for `openApplication`, not network addresses.

## Limitations

- Some apps set a minimum or fixed window size; WindowSnap beeps when an app refuses a new frame
- While another program (a screen reader, or some other tools) has an app's "enhanced user interface" setting switched on, that app animates every change to its windows, and a change sent during the animation cancels the one before it, so a snap that both moves and resizes would land in the wrong place. WindowSnap switches that setting off for that app for the moment of the move and straight back on. It never switches it on in an app where it was off. Apple has not published this setting's name (`AXEnhancedUserInterface`); the open-source window manager Rectangle switches it off around a move for the same reason
- Full-screen windows (green button) can't be moved; leave full screen first
- The switcher and arrange list what each app reports through the Accessibility API; apps with custom, non-accessible windows may not appear. Windows on other desktops or in full screen aren't listed one by one; their app gets a "No windows on this desktop" line only when it has no window on the current desktop, and arrange can't pick them
- Finder windows on another desktop: choosing Finder doesn't switch desktops (see Window switcher)
- Arrange brings the picked windows' apps forward one at a time; macOS can refuse quick app switches, so a window may land in place but behind another window
- Tabs appear only for apps with a standard Accessibility tab bar; apps that draw their own tabs (like Obsidian) show none. WindowSnap doesn't switch on any setting in other apps to expose more
- Option+S normally types ß, and Option+Tab can type a tab character in some text fields; with WindowSnap running, those open the switcher instead
- If another app uses the same shortcut, the two can clash; the menu only marks shortcuts macOS refused to register

## Remove

1. Quit WindowSnap from its menu bar icon (turn off **Open at Login** first, or remove it in System Settings > General > Login Items)
2. System Settings > Privacy & Security > Accessibility: select WindowSnap and click the minus button
3. Delete `~/Applications/WindowSnap.app` and this folder

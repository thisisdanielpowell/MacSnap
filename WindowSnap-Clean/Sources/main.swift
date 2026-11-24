// main.swift
// Entry point: starts WindowSnap as a menu bar app (no Dock icon, no main window).

import Cocoa

let app: NSApplication = NSApplication.shared
let delegate: AppDelegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

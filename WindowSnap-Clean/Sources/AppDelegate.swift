// AppDelegate.swift
// The menu bar app: defines the shortcuts, registers them, builds the menu (including Open at Login),
// and asks for the Accessibility permission that moving and switching windows need.

import Carbon.HIToolbox
import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Every shortcut. Snapping uses Control+Option, so WindowSnap leaves the fn/Globe key, plain Control
    /// shortcuts (Spaces, Terminal), and macOS's own window tiling shortcuts untouched.
    /// The switcher uses Option+Tab and Option+S.
    static let hotkeys: [Hotkey] = [
        Hotkey(keyCode: kVK_LeftArrow, modifiers: controlOption, command: .snap(.left), label: "Ctrl+Option+Left: left side (again: 2/3, 1/3)"),
        Hotkey(keyCode: kVK_RightArrow, modifiers: controlOption, command: .snap(.right), label: "Ctrl+Option+Right: right side (again: 2/3, 1/3)"),
        Hotkey(keyCode: kVK_UpArrow, modifiers: controlOption, command: .snap(.top), label: "Ctrl+Option+Up: top half"),
        Hotkey(keyCode: kVK_DownArrow, modifiers: controlOption, command: .snap(.bottom), label: "Ctrl+Option+Down: bottom half"),
        Hotkey(keyCode: kVK_ANSI_U, modifiers: controlOption, command: .snap(.topLeft), label: "Ctrl+Option+U: top-left"),
        Hotkey(keyCode: kVK_ANSI_I, modifiers: controlOption, command: .snap(.topRight), label: "Ctrl+Option+I: top-right"),
        Hotkey(keyCode: kVK_ANSI_J, modifiers: controlOption, command: .snap(.bottomLeft), label: "Ctrl+Option+J: bottom-left"),
        Hotkey(keyCode: kVK_ANSI_K, modifiers: controlOption, command: .snap(.bottomRight), label: "Ctrl+Option+K: bottom-right"),
        Hotkey(keyCode: kVK_ANSI_C, modifiers: controlOption, command: .snap(.center), label: "Ctrl+Option+C: center"),
        Hotkey(keyCode: kVK_ANSI_F, modifiers: controlOption, command: .snap(.sixteenNine), label: "Ctrl+Option+F: 16:9"),
        Hotkey(keyCode: kVK_ANSI_M, modifiers: controlOption, command: .snap(.nextDisplay), label: "Ctrl+Option+M: next display"),
        Hotkey(keyCode: kVK_ANSI_R, modifiers: controlOption, command: .arrange, label: "Ctrl+Option+R: arrange 2 to 4 windows (again within 3 s: next layout)"),
        Hotkey(keyCode: kVK_Tab, modifiers: optionKey, command: .switcherNext, label: "Option+Tab: switch windows (hold Option, release to switch)"),
        Hotkey(keyCode: kVK_Tab, modifiers: optionKey | shiftKey, command: .switcherPrevious, label: "Option+Shift+Tab: switch windows, backward"),
        Hotkey(keyCode: kVK_ANSI_S, modifiers: optionKey, command: .switcherSearch, label: "Option+S: search windows"),
    ]

    /// Carbon modifier flags for Control+Option.
    private static let controlOption: Int = controlKey | optionKey

    private let mover: WindowMover
    private let switcher: SwitcherController
    private let arranger: ArrangeController
    /// The orange outline shown after a snap or an arrangement.
    private let highlight: SnapHighlight = SnapHighlight()
    /// Held so the menu bar icon stays on screen for the life of the app.
    private var statusItem: NSStatusItem?
    private let permissionLine: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem: NSMenuItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")

    override init() {
        // One window list and one mover, shared so the switcher and the arrange picker agree.
        let catalog: WindowCatalog = WindowCatalog()
        let mover: WindowMover = WindowMover()
        self.mover = mover
        self.switcher = SwitcherController(catalog: catalog)
        self.arranger = ArrangeController(catalog: catalog, mover: mover)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let unavailable: [String] = HotkeyCenter.shared.register(Self.hotkeys)
        HotkeyCenter.shared.onHotkey = { [weak self] (command: HotkeyCommand) in
            self?.run(command)
        }
        mover.onMoved = { [weak self] (frames: [CGRect]) in
            self?.highlight.flash(frames)
        }
        buildMenu(unavailable: unavailable)
        requestAccessibilityIfNeeded()
    }

    /// Sends each shortcut to the part of the app that handles it.
    private func run(_ command: HotkeyCommand) {
        switch command {
        case .snap(let action): mover.perform(action)
        case .switcherNext: switcher.next()
        case .switcherPrevious: switcher.previous()
        case .switcherSearch: switcher.search()
        case .arrange: arranger.arrangeOrCycle()
        }
    }

    /// Refreshes the permission line and the login checkmark each time the menu opens, so neither shows a stale state.
    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionLine()
        updateLoginItem()
    }

    // MARK: - Setup

    /// Builds the menu bar icon and its menu: permission status, the shortcut list, Open at Login, and Quit.
    /// - Parameter unavailable: Shortcut labels macOS refused to register.
    private func buildMenu(unavailable: [String]) {
        let item: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "WindowSnap")

        let menu: NSMenu = NSMenu()
        menu.delegate = self
        menu.addItem(permissionLine)
        menu.addItem(.separator())
        for hotkey: Hotkey in Self.hotkeys {
            let refused: Bool = unavailable.contains(hotkey.label)
            menu.addItem(NSMenuItem(title: refused ? "\(hotkey.label) (could not register)" : hotkey.label, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit WindowSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        updatePermissionLine()
        updateLoginItem()
    }

    /// Shows macOS's Accessibility prompt if WindowSnap isn't allowed yet.
    /// The option key is written as its documented string value ("AXTrustedCheckOptionPrompt"),
    /// because the imported constant is a mutable global that strict Swift 6 concurrency rejects.
    private func requestAccessibilityIfNeeded() {
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func updatePermissionLine() {
        permissionLine.title = AXIsProcessTrusted()
            ? "Running"
            : "Needs Accessibility: System Settings > Privacy & Security > Accessibility"
    }

    // MARK: - Open at Login

    /// Turns starting at login on or off with Apple's login item API (SMAppService). It needs no extra
    /// permission, and the setting also shows in System Settings > General > Login Items, where it can be turned off.
    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service: SMAppService = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
        updateLoginItem()
    }

    /// Shows a checkmark when WindowSnap is set to open at login.
    private func updateLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

// ArrangeController.swift
// Ctrl+Option+R: pick 2 to 4 windows, then arrange them side by side with the same gaps as snapping.
// Pressing Ctrl+Option+R again within 3 seconds of arranging moves those windows to the next layout
// (see SnapLayout.arrangements); after that, Ctrl+Option+R opens the picker for a new set.
//
// Security: same as the switcher. Keys reach WindowSnap only while its own picker is open and focused.
// The window list is dropped when the picker closes. For the 3-second cycle it keeps only references
// to the arranged windows and their apps (no titles), and drops those when the cycle time passes.

import Carbon.HIToolbox
import Cocoa

@MainActor
final class ArrangeController: NSObject, NSWindowDelegate {
    /// Most windows one arrangement can hold.
    static let maxWindows: Int = 4
    /// How long after arranging a second Ctrl+Option+R cycles the layout instead of opening the picker.
    static let cycleSeconds: TimeInterval = 3

    /// The windows from the last arrangement, kept only for the cycle time.
    private struct Arrangement {
        let windows: [AXUIElement]
        let apps: [NSRunningApplication]
        let layout: Int
        let time: Date
    }

    private let catalog: WindowCatalog
    private let mover: WindowMover
    private let panel: SwitcherPanel = SwitcherPanel()
    private var items: [SwitcherItem] = []
    /// Indices into `items`, in the order they were picked.
    private var picked: [Int] = []
    private var selection: Int = 0
    private var isOpen: Bool = false
    private var previousApp: NSRunningApplication?
    private var last: Arrangement?

    /// - Parameters:
    ///   - catalog: The shared window list, so recent-use order matches the switcher.
    ///   - mover: The shared window mover, which places the windows.
    init(catalog: WindowCatalog, mover: WindowMover) {
        self.catalog = catalog
        self.mover = mover
        super.init()
        panel.delegate = self
        panel.onKey = { [weak self] (event: NSEvent) -> Bool in
            self?.handleKey(event) ?? false
        }
    }

    // MARK: - Hotkey entry point

    /// Ctrl+Option+R: cycles the last arrangement's layout if it was within the cycle time, otherwise opens the picker.
    func arrangeOrCycle() {
        guard !isOpen else { return }
        if let last: Arrangement = last, Date().timeIntervalSince(last.time) < Self.cycleSeconds {
            let count: Int = SnapLayout.layoutCount(for: last.windows.count)
            apply(windows: last.windows, apps: last.apps, layout: count > 0 ? (last.layout + 1) % count : 0)
        } else {
            last = nil
            open()
        }
    }

    // MARK: - Picker

    private func open() {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        items = catalog.currentItems()
        picked = []
        selection = 0
        isOpen = true
        render()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
    }

    /// Space: picks or un-picks the highlighted window, up to `maxWindows`.
    private func togglePick() {
        guard items.indices.contains(selection) else { return }
        if let position: Int = picked.firstIndex(of: selection) {
            picked.remove(at: position)
        } else if picked.count < Self.maxWindows {
            picked.append(selection)
        } else {
            NSSound.beep()
        }
        render()
    }

    /// Return: arranges the picked windows, in pick order, using the first layout for that count.
    private func arrangePicked() {
        guard picked.count >= 2 else {
            NSSound.beep()
            return
        }
        let chosen: [SwitcherItem] = picked.map { items[$0] }
        close(restoringFocus: false)
        apply(windows: chosen.map { $0.window }, apps: chosen.map { $0.app }, layout: 0)
    }

    /// Places the windows, brings them forward (last picked first, so the first pick ends up in front),
    /// and starts the cycle timer.
    private func apply(windows: [AXUIElement], apps: [NSRunningApplication], layout: Int) {
        for (window, app): (AXUIElement, NSRunningApplication) in zip(windows, apps).reversed() {
            catalog.activate(window: window, app: app)
        }
        if !mover.arrange(windows, layout: layout) {
            NSSound.beep()
        }
        last = Arrangement(windows: windows, apps: apps, layout: layout, time: Date())
        // Drop the window references once the cycle time has passed.
        let stamp: Date = last?.time ?? Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cycleSeconds) { [weak self] in
            MainActor.assumeIsolated {
                if self?.last?.time == stamp {
                    self?.last = nil
                }
            }
        }
    }

    private func move(by step: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + step % items.count + items.count) % items.count
        render()
    }

    /// Hides the picker and forgets the window list.
    /// - Parameter restoringFocus: Bring back the app that was in front before the picker opened.
    private func close(restoringFocus: Bool) {
        guard isOpen else { return }
        isOpen = false
        let restore: NSRunningApplication? = restoringFocus ? previousApp : nil
        previousApp = nil
        panel.orderOut(nil)
        items = []
        picked = []
        restore?.activate(options: [])
    }

    private func render() {
        var picks: [Int: Int] = [:]
        for (order, index): (Int, Int) in picked.enumerated() { picks[index] = order + 1 }
        let rows: [PanelRow] = items.enumerated().map { (index: Int, item: SwitcherItem) -> PanelRow in
            item.panelRow(pick: picks[index])
        }
        let hint: String = "Space: pick 2 to 4 windows (\(picked.count) picked)    Return: arrange    Esc: cancel"
        panel.show(rows: rows, selected: selection, searching: false, hint: hint)
    }

    // MARK: - Keys while the picker is focused

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close(restoringFocus: true)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            arrangePicked()
        case kVK_Space:
            togglePick()
        case kVK_DownArrow, kVK_Tab:
            move(by: 1)
        case kVK_UpArrow:
            move(by: -1)
        default:
            return false
        }
        return true
    }

    /// Clicking anywhere outside the picker closes it without arranging.
    func windowDidResignKey(_ notification: Notification) {
        close(restoringFocus: false)
    }
}

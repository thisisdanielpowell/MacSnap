// SwitcherController.swift
// The window switcher's behavior: open on Option+Tab or Option+S, move the highlight,
// show a window's tabs with the Right arrow, search windows and tabs, list apps with no window
// on this desktop (like Cmd+Tab), switch on Option release or Return, quit an app with Q,
// cancel with Esc.
//
// Security: WindowSnap receives keys only while its own panel is open and focused,
// the same way any app receives keys while you type in it. To notice Option being released,
// it reads which modifier keys are held (Shift, Control, Option, Command), never letters.
// The window and tab lists and the search text are dropped as soon as the panel closes.
// Tabs are read only when needed: when you expand a window, or when you search.

import Carbon.HIToolbox
import Cocoa

@MainActor
final class SwitcherController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private enum Mode {
        /// Opened with Option+Tab: switches when Option is released.
        case cycle
        /// Opened with Option+S: type to filter windows and tabs, Return to switch.
        case search
    }

    /// One line of the list: a window, one of its tabs, or an app with no window on this desktop.
    private enum Entry {
        /// Index into `allItems`.
        case window(Int)
        /// Index of the owning window in `allItems`, and the tab.
        case tab(Int, TabItem)
        /// An app with no window on this desktop: its windows are on another desktop or in full screen,
        /// or it has none open. Choosing it activates the app, like Cmd+Tab.
        case appWithoutWindows(NSRunningApplication)

        /// The window this line belongs to, or nil for an app line.
        var windowIndex: Int? {
            switch self {
            case .window(let index), .tab(let index, _): return index
            case .appWithoutWindows: return nil
            }
        }
    }

    private let catalog: WindowCatalog
    private let panel: SwitcherPanel = SwitcherPanel()
    /// Apps in recent-use order, for placing lines.
    private var appOrder: [NSRunningApplication] = []
    private var allItems: [SwitcherItem] = []
    /// Apps with no window on this desktop, by process ID.
    private var appsWithoutWindows: Set<pid_t> = []
    private var entries: [Entry] = []
    /// Windows whose tabs are shown under them (indices into `allItems`).
    private var expanded: Set<Int> = []
    /// Tabs already read this time the panel is open, by window index.
    private var tabCache: [Int: [TabItem]] = [:]
    private var selection: Int = 0
    private var mode: Mode = .cycle
    private var isOpen: Bool = false
    /// The app that was in front before the switcher opened, restored on cancel.
    private var previousApp: NSRunningApplication?
    /// Checks for Option release while the switcher is open in cycle mode.
    private var optionWatch: Timer?

    /// - Parameter catalog: The shared window list, so recent-use order matches the arrange picker.
    init(catalog: WindowCatalog) {
        self.catalog = catalog
        super.init()
        panel.delegate = self
        panel.searchField.delegate = self
        panel.onKey = { [weak self] (event: NSEvent) -> Bool in
            self?.handleKey(event) ?? false
        }
    }

    // MARK: - Hotkey entry points

    /// Option+Tab: opens on the previous window, or moves the highlight down if already open.
    func next() {
        if isOpen { move(by: 1) } else { open(.cycle, selecting: 1) }
    }

    /// Option+Shift+Tab: opens on the last window, or moves the highlight up if already open.
    func previous() {
        if isOpen { move(by: -1) } else { open(.cycle, selecting: Int.max) }
    }

    /// Option+S: opens in search mode, or switches an open switcher to search mode.
    func search() {
        if isOpen {
            mode = .search
            stopWatchingOption()
            rebuildEntries()
            render()
            panel.makeFirstResponder(panel.searchField)
        } else {
            open(.search, selecting: 0)
        }
    }

    // MARK: - Open, move, choose, close

    private func open(_ newMode: Mode, selecting index: Int) {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        appOrder = catalog.appsByRecency()
        allItems = catalog.currentItems()
        appsWithoutWindows = catalog.appsWithoutListedWindows(appOrder, listed: allItems)
        expanded = []
        tabCache = [:]
        mode = newMode
        panel.searchField.stringValue = ""
        rebuildEntries()
        selection = entries.isEmpty ? 0 : min(max(index, 0), entries.count - 1)
        isOpen = true
        render()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if newMode == .search {
            panel.makeFirstResponder(panel.searchField)
        } else {
            panel.makeFirstResponder(nil)
            watchForOptionRelease()
        }
    }

    private func move(by step: Int) {
        guard !entries.isEmpty else { return }
        selection = (selection + step % entries.count + entries.count) % entries.count
        render()
    }

    /// Switches to the highlighted window, tab, or app, or just closes if there is none.
    private func choose() {
        let entry: Entry? = entries.indices.contains(selection) ? entries[selection] : nil
        let items: [SwitcherItem] = allItems
        close(restoringFocus: entry == nil)
        switch entry {
        case .window(let index): catalog.activate(items[index])
        case .tab(_, let tab): catalog.select(tab)
        case .appWithoutWindows(let app): catalog.activate(app: app)
        case nil: break
        }
    }

    /// Hides the panel and forgets the window and tab lists and the search text.
    /// - Parameter restoringFocus: Bring back the app that was in front before the switcher opened.
    private func close(restoringFocus: Bool) {
        guard isOpen else { return }
        isOpen = false
        let restore: NSRunningApplication? = restoringFocus ? previousApp : nil
        previousApp = nil
        stopWatchingOption()
        panel.orderOut(nil)
        appOrder = []
        allItems = []
        appsWithoutWindows = []
        entries = []
        expanded = []
        tabCache = [:]
        panel.searchField.stringValue = ""
        restore?.activate(options: [])
    }

    /// Q: asks the highlighted line's app to quit and removes its lines from the list.
    private func quitSelected() {
        guard entries.indices.contains(selection) else { return }
        let app: NSRunningApplication
        switch entries[selection] {
        case .window(let index), .tab(let index, _): app = allItems[index].app
        case .appWithoutWindows(let listedApp): app = listedApp
        }
        catalog.quit(app)
        allItems.removeAll { $0.app == app }
        appsWithoutWindows.remove(app.processIdentifier)
        // Window indices shifted, so expanded windows and cached tabs start over.
        expanded = []
        tabCache = [:]
        rebuildEntries()
        selection = min(selection, max(entries.count - 1, 0))
        render()
    }

    // MARK: - Tabs

    /// The window's tabs, read once per panel opening.
    private func tabs(forWindow index: Int) -> [TabItem] {
        if let cached: [TabItem] = tabCache[index] { return cached }
        let read: [TabItem] = catalog.tabs(of: allItems[index])
        tabCache[index] = read
        return read
    }

    /// Right arrow: shows the highlighted window's tabs under it. Beeps if the app exposes none.
    private func expandSelected() {
        guard entries.indices.contains(selection), case .window(let index) = entries[selection] else { return }
        guard !tabs(forWindow: index).isEmpty else {
            NSSound.beep()
            return
        }
        expanded.insert(index)
        rebuildEntries()
        render()
    }

    /// Left arrow: hides the tabs of the highlighted window (or of the highlighted tab's window).
    private func collapseSelected() {
        guard entries.indices.contains(selection), let index: Int = entries[selection].windowIndex else { return }
        expanded.remove(index)
        rebuildEntries()
        selection = entries.firstIndex { if case .window(let i) = $0 { return i == index } else { return false } } ?? 0
        render()
    }

    // MARK: - List

    /// Rebuilds the visible lines, app by app in recent-use order: each app's windows (with tabs under
    /// expanded windows), or one app line if it has no window on this desktop.
    /// Searching shows only windows, tabs, and apps whose title or app name matches.
    private func rebuildEntries() {
        let query: String = mode == .search ? panel.searchField.stringValue : ""
        var list: [Entry] = []
        for app: NSRunningApplication in appOrder {
            for index: Int in allItems.indices where allItems[index].app == app {
                if query.isEmpty {
                    list.append(.window(index))
                    if expanded.contains(index) {
                        list += tabs(forWindow: index).map { Entry.tab(index, $0) }
                    }
                } else {
                    let matchingTabs: [TabItem] = tabs(forWindow: index).filter { $0.matches(query) }
                    if allItems[index].matches(query) || !matchingTabs.isEmpty {
                        list.append(.window(index))
                    }
                    list += matchingTabs.map { Entry.tab(index, $0) }
                }
            }
            if appsWithoutWindows.contains(app.processIdentifier),
               query.isEmpty || searchMatches(query, in: app.localizedName ?? "") {
                list.append(.appWithoutWindows(app))
            }
        }
        entries = list
    }

    private func render() {
        let rows: [PanelRow] = entries.map { (entry: Entry) -> PanelRow in
            switch entry {
            case .window(let index):
                return allItems[index].panelRow(tabCount: tabCache[index]?.count)
            case .tab(_, let tab):
                return tab.panelRow
            case .appWithoutWindows(let app):
                return PanelRow(icon: app.icon, title: app.localizedName ?? "App", detail: "No windows on this desktop")
            }
        }
        panel.show(rows: rows, selected: selection, searching: mode == .search)
    }

    // MARK: - Option release

    private func watchForOptionRelease() {
        stopWatchingOption()
        optionWatch = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] (_: Timer) in
            MainActor.assumeIsolated {
                // Reads only which modifier keys are held, not any other key.
                if !NSEvent.modifierFlags.contains(.option) {
                    self?.choose()
                }
            }
        }
    }

    private func stopWatchingOption() {
        optionWatch?.invalidate()
        optionWatch = nil
    }

    // MARK: - Keys while the panel is focused

    /// Keys in cycle mode. Tab with Option held arrives through the Option+Tab hotkey instead.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close(restoringFocus: true)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            choose()
        case kVK_DownArrow:
            move(by: 1)
        case kVK_UpArrow:
            move(by: -1)
        case kVK_RightArrow:
            expandSelected()
        case kVK_LeftArrow:
            collapseSelected()
        case kVK_Tab:
            move(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_ANSI_Q:
            quitSelected()
        default:
            return false
        }
        return true
    }

    /// Search mode: filter windows and tabs as the search text changes.
    func controlTextDidChange(_ notification: Notification) {
        rebuildEntries()
        selection = 0
        render()
    }

    /// Search mode: Up, Down, and Tab move, Return switches, Esc cancels.
    /// Left and Right stay with the search text (moving the cursor); matching tabs are already listed.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            choose()
        case #selector(NSResponder.cancelOperation(_:)):
            close(restoringFocus: true)
        default:
            return false
        }
        return true
    }

    /// Clicking anywhere outside the panel closes it without switching.
    func windowDidResignKey(_ notification: Notification) {
        close(restoringFocus: false)
    }
}

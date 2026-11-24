// WindowCatalog.swift
// Builds the window list shared by the switcher and arrange, reads a window's tabs,
// finds apps with no window on this desktop, and brings a chosen window, tab, or app forward.
//
// Security: window and tab titles come from the Accessibility API (the permission WindowSnap already has).
// They exist only while a panel is open and are never saved or sent anywhere. Reading tabs is read-only;
// the one action is pressing a tab's button when you choose that tab.
// Recent-use order comes from macOS's public "app became active" notification, which needs no permission.

import ApplicationServices
import Cocoa

/// One window shown in the switcher.
struct SwitcherItem {
    let app: NSRunningApplication
    let window: AXUIElement
    /// The window's title, or the app name when the window has none.
    let title: String
    let isMinimized: Bool

    var appName: String { app.localizedName ?? "App" }

    /// True when every search word appears in the title or app name.
    func matches(_ query: String) -> Bool {
        searchMatches(query, in: "\(title) \(appName)")
    }
}

/// One tab inside a window (browser tabs, Terminal tabs, Finder tabs), read through Accessibility.
struct TabItem {
    /// The window that holds the tab.
    let owner: SwitcherItem
    /// The tab's button in the window's tab bar.
    let element: AXUIElement
    let title: String

    /// True when every search word appears in the tab title or the app name.
    func matches(_ query: String) -> Bool {
        searchMatches(query, in: "\(title) \(owner.appName)")
    }
}

/// True when every word of the query appears in the text (case and accent insensitive).
func searchMatches(_ query: String, in text: String) -> Bool {
    query.split(separator: " ").allSatisfy { (word: Substring) -> Bool in
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

@MainActor
final class WindowCatalog {
    /// Process IDs of apps in the order they were last active, most recent first.
    private var recentPIDs: [pid_t] = []

    init() {
        if let front: NSRunningApplication = NSWorkspace.shared.frontmostApplication {
            recentPIDs = [front.processIdentifier]
        }
        // The catalog lives as long as the app, so this observer is never removed.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] (note: Notification) in
            let app: NSRunningApplication? = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid: pid_t = app?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.markRecent(pid) }
        }
    }

    /// Lists switchable windows: regular apps only (not WindowSnap, menu bar helpers, or background agents),
    /// most recently used app first, each app's windows in the order the app reports them.
    /// Only windows on the current desktop are included; see `appsWithoutListedWindows`.
    func currentItems() -> [SwitcherItem] {
        appsByRecency().flatMap { (app: NSRunningApplication) -> [SwitcherItem] in windows(of: app) }
    }

    /// Regular apps (not WindowSnap, menu bar helpers, or background agents), most recently used first.
    func appsByRecency() -> [NSRunningApplication] {
        let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
        let apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications.filter { (app: NSRunningApplication) -> Bool in
            app.activationPolicy == .regular && app.processIdentifier != ownPID
        }
        var rank: [pid_t: Int] = [:]
        for (index, pid): (Int, pid_t) in recentPIDs.enumerated() { rank[pid] = index }
        return apps.sorted { (a: NSRunningApplication, b: NSRunningApplication) -> Bool in
            (rank[a.processIdentifier] ?? Int.max) < (rank[b.processIdentifier] ?? Int.max)
        }
    }

    // MARK: - Apps without windows on this desktop

    /// Process IDs of apps that have no window in the Accessibility list, which covers only the current
    /// desktop. These are apps whose windows are all on another desktop or in full screen, or that have
    /// no windows open; the switcher lists each as one line, like Cmd+Tab.
    /// (Counting off-screen windows from the window server was tried and dropped on 2026-11-24: nearly every
    /// app has an invisible helper window there, so minimized and phantom windows looked like other desktops.)
    /// - Parameters:
    ///   - apps: The apps to check.
    ///   - listed: The windows already listed from Accessibility.
    func appsWithoutListedWindows(_ apps: [NSRunningApplication], listed: [SwitcherItem]) -> Set<pid_t> {
        let withWindows: Set<pid_t> = Set(listed.map { $0.app.processIdentifier })
        return Set(apps.map { $0.processIdentifier }.filter { !withWindows.contains($0) })
    }

    /// Brings forward an app that has no window on this desktop, the same as clicking its Dock icon:
    /// macOS sends the running app a "reopen" request, which in most apps restores a minimized window,
    /// moves to the desktop where its windows are, or opens a new window if it has none.
    /// It never starts a second copy of the app.
    func activate(app: NSRunningApplication) {
        guard let url: URL = app.bundleURL else {
            app.activate(options: [])
            return
        }
        let configuration: NSWorkspace.OpenConfiguration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { (_: NSRunningApplication?, _: (any Error)?) in }
    }

    /// Brings a window forward: un-minimizes it if needed, raises it, and activates its app.
    func activate(_ item: SwitcherItem) {
        activate(window: item.window, app: item.app)
    }

    /// Brings a window forward, checking live whether it is minimized.
    /// - Parameters:
    ///   - window: The window to raise.
    ///   - app: The app that owns it.
    func activate(window: AXUIElement, app: NSRunningApplication) {
        if AX.bool(window, kAXMinimizedAttribute) == true {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate(options: [])
    }

    /// Asks an app to quit normally, the same as choosing Quit from its menu. The app can still ask to save.
    func quit(_ app: NSRunningApplication) {
        app.terminate()
    }

    // MARK: - Tabs

    /// Deepest level of a window's Accessibility tree searched for a tab bar.
    private static let maxTabSearchDepth: Int = 12
    /// Most elements looked at per window, so a huge window can't stall the switcher.
    private static let maxTabSearchElements: Int = 3000

    /// Subrole some apps give their tab buttons. Apple's headers have no named constant for it.
    private static let tabButtonSubrole: String = "AXTabButton"

    /// Parts of a window that never hold a tab bar, so the tab search doesn't go inside them:
    /// web page content (browsers and web-based apps like Obsidian, Teams, Outlook), file lists,
    /// tables, and text areas. These are by far the largest parts of most windows.
    private static let rolesWithoutTabs: Set<String> = [
        "AXWebArea", kAXTableRole, kAXOutlineRole, kAXBrowserRole, kAXTextAreaRole,
    ]

    /// Reads a window's tabs, in tab bar order. Read-only; returns an empty list if the app
    /// doesn't expose its tabs through Accessibility.
    func tabs(of item: SwitcherItem) -> [TabItem] {
        var found: [TabItem] = []
        var visited: Int = 0
        collectTabs(in: item.window, owner: item, depth: 0, visited: &visited, into: &found)
        return found
    }

    /// Switches to a tab: brings its window forward, then presses the tab's button,
    /// the same as clicking the tab.
    func select(_ tab: TabItem) {
        activate(tab.owner)
        _ = AXUIElementPerformAction(tab.element, kAXPressAction as CFString)
    }

    /// Walks the Accessibility tree for tab buttons: radio buttons inside a tab group (Terminal, Finder, Safari),
    /// or elements marked as tab buttons (Chrome, Edge). Stops descending once a tab bar is found, and skips
    /// parts that never hold one. Each element is read with one batched request.
    private func collectTabs(in element: AXUIElement, owner: SwitcherItem, depth: Int, visited: inout Int, into found: inout [TabItem]) {
        guard depth <= Self.maxTabSearchDepth, visited < Self.maxTabSearchElements else { return }
        visited += 1

        let values: [CFTypeRef?] = AX.attributes(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute])
        let role: String = AX.asString(values[0]) ?? ""
        if AX.asString(values[1]) == Self.tabButtonSubrole {
            found.append(tabItem(element, owner: owner))
            return
        }
        if Self.rolesWithoutTabs.contains(role) { return }

        let children: [AXUIElement] = AX.asElements(values[2])
        if role == kAXTabGroupRole {
            let buttons: [AXUIElement] = children.filter { AX.string($0, kAXRoleAttribute) == kAXRadioButtonRole }
            if !buttons.isEmpty {
                found.append(contentsOf: buttons.map { tabItem($0, owner: owner) })
                return
            }
        }
        for child: AXUIElement in children {
            collectTabs(in: child, owner: owner, depth: depth + 1, visited: &visited, into: &found)
        }
    }

    private func tabItem(_ element: AXUIElement, owner: SwitcherItem) -> TabItem {
        let values: [CFTypeRef?] = AX.attributes(element, [kAXTitleAttribute, kAXDescriptionAttribute])
        let title: String = AX.asString(values[0]).flatMap { $0.isEmpty ? nil : $0 } ?? AX.asString(values[1]) ?? ""
        return TabItem(owner: owner, element: element, title: title.isEmpty ? "Tab" : title)
    }

    // MARK: - Private

    private func markRecent(_ pid: pid_t) {
        recentPIDs.removeAll { $0 == pid }
        recentPIDs.insert(pid, at: 0)
    }

    /// An app's standard windows (not panels, sheets, or popovers), plus any minimized window,
    /// since some apps (Outlook, for one) don't mark a minimized window as standard.
    private func windows(of app: NSRunningApplication) -> [SwitcherItem] {
        let axApp: AXUIElement = AXUIElementCreateApplication(app.processIdentifier)
        return AX.elements(axApp, kAXWindowsAttribute).compactMap { (window: AXUIElement) -> SwitcherItem? in
            let isMinimized: Bool = AX.bool(window, kAXMinimizedAttribute) ?? false
            guard isMinimized || AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return nil }
            let title: String = AX.string(window, kAXTitleAttribute) ?? ""
            return SwitcherItem(
                app: app,
                window: window,
                title: title.isEmpty ? (app.localizedName ?? "Window") : title,
                isMinimized: isMinimized
            )
        }
    }
}

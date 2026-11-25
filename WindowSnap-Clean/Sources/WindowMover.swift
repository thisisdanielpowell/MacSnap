// WindowMover.swift
// Moves and resizes windows through the macOS Accessibility API: the focused window for snapping,
// several windows for arranging. It reads and sets two attributes per window, position and size.
// Where another program has an app's "enhanced user interface" setting on, it switches that setting
// off for the moment of a move and straight back on (see `setFrame`). Nothing else: no window
// contents, no clicks, no typing. After a move it reports where the windows landed, for the orange
// highlight.

import ApplicationServices
import Cocoa

@MainActor
final class WindowMover {
    /// Called with where the windows actually landed after a snap or an arrangement, read back from
    /// the apps (an app can refuse a size), so the highlight outlines the real frame.
    var onMoved: (([CGRect]) -> Void)?

    /// The last action and window, kept only so repeated Left or Right presses cycle sizes.
    private var lastAction: SnapAction?
    private var lastWindow: AXUIElement?
    private var cycleIndex: Int = 0

    /// Applies an action to the focused window. Beeps when there is no permission, no window,
    /// or the app refuses the new frame.
    /// - Parameter action: The placement to apply.
    func perform(_ action: SnapAction) {
        guard AXIsProcessTrusted(), let window: AXUIElement = focusedWindow(), let current: CGRect = frame(of: window) else {
            NSSound.beep()
            return
        }
        let currentScreen: NSScreen = screenContaining(current)
        let target: CGRect

        if action == .nextDisplay {
            guard let next: NSScreen = screenAfter(currentScreen) else {
                NSSound.beep()
                return
            }
            target = SnapLayout.frameOnNextScreen(current, from: usableArea(of: currentScreen), to: usableArea(of: next))
            lastAction = nil
            lastWindow = nil
        } else {
            let repeated: Bool = lastAction == action && lastWindow.map { CFEqual($0, window) } == true
            cycleIndex = repeated ? (cycleIndex + 1) % SnapLayout.sideFractions.count : 0
            lastAction = action
            lastWindow = window
            guard let frame: CGRect = SnapLayout.frame(for: action, current: current, area: usableArea(of: currentScreen), cycleIndex: cycleIndex) else {
                return
            }
            target = frame
        }

        if !setFrame(target.integral, of: window) {
            NSSound.beep()
        }
        if let landed: CGRect = frame(of: window) {
            onMoved?([landed])
        }
    }

    // MARK: - Arranging several windows

    /// Arranges windows into one of SnapLayout's multi-window layouts, on the screen of the first window.
    /// - Parameters:
    ///   - windows: The windows, in pick order (2 to 4).
    ///   - layout: Which layout for that number of windows; wraps around.
    /// - Returns: False if a window couldn't be read or refused its new frame.
    func arrange(_ windows: [AXUIElement], layout: Int) -> Bool {
        guard AXIsProcessTrusted(), let first: AXUIElement = windows.first, let firstFrame: CGRect = frame(of: first) else {
            return false
        }
        let frames: [CGRect] = SnapLayout.arrangement(windowCount: windows.count, layout: layout, area: usableArea(of: screenContaining(firstFrame)))
        guard frames.count == windows.count else { return false }
        var allPlaced: Bool = true
        for (window, target): (AXUIElement, CGRect) in zip(windows, frames) {
            if !setFrame(target.integral, of: window) {
                allPlaced = false
            }
        }
        onMoved?(windows.compactMap { frame(of: $0) })
        // An arrangement ends any Left/Right size cycle in progress.
        lastAction = nil
        lastWindow = nil
        return allPlaced
    }

    // MARK: - Accessibility reads and writes

    /// Returns the focused window of the frontmost app, or nil if it has none.
    private func focusedWindow() -> AXUIElement? {
        guard let app: NSRunningApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        return AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
    }

    /// Reads a window's position and size, or nil if the app doesn't report them.
    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position: CGPoint = AX.value(window, kAXPositionAttribute, type: .cgPoint, empty: CGPoint.zero),
              let size: CGSize = AX.value(window, kAXSizeAttribute, type: .cgSize, empty: CGSize.zero)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Sets a window's frame. Returns false if the app refused any part of it.
    /// Size is set before and after the move: some apps limit size to the screen the window is on,
    /// so the second size call lands it correctly after a move between displays.
    /// While another program has the app's "enhanced user interface" setting on, the app animates each
    /// of these changes, and a change sent during the animation cancels the one before it: a snap that
    /// both moves and resizes then lands in the wrong place. So where the setting is on, it is switched
    /// off for these three requests and straight back on. It is never switched on where it was off.
    private func setFrame(_ rect: CGRect, of window: AXUIElement) -> Bool {
        var size: CGSize = rect.size
        var position: CGPoint = rect.origin
        guard let sizeValue: AXValue = AXValueCreate(.cgSize, &size),
              let positionValue: AXValue = AXValueCreate(.cgPoint, &position)
        else { return false }
        let animatingApp: AXUIElement? = appWithEnhancedUserInterface(of: window)
        if let animatingApp { setEnhancedUserInterface(false, for: animatingApp) }
        defer { if let animatingApp { setEnhancedUserInterface(true, for: animatingApp) } }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let moved: AXError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sized: AXError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return moved == .success && sized == .success
    }

    // MARK: - Enhanced user interface

    /// The setting's name. Apple has not published it. Screen readers and some other tools switch it
    /// on for an app, and the app then animates window changes made through the Accessibility API.
    private static let enhancedUserInterface: String = "AXEnhancedUserInterface"

    /// Returns the window's app if it has "enhanced user interface" switched on, or nil otherwise.
    private func appWithEnhancedUserInterface(of window: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let app: AXUIElement = AXUIElementCreateApplication(pid)
        return AX.bool(app, Self.enhancedUserInterface) == true ? app : nil
    }

    /// Switches "enhanced user interface" on or off for an app. The answer is not checked: apps answer
    /// "not implemented" to this request even when it has worked (seen with Finder, iTerm2, Chrome and
    /// plain AppKit apps on macOS 27.2), so the answer says nothing either way.
    private func setEnhancedUserInterface(_ on: Bool, for app: AXUIElement) {
        _ = AXUIElementSetAttributeValue(app, Self.enhancedUserInterface as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // MARK: - Screens

    /// Converts a Cocoa rectangle (origin bottom-left) to Accessibility coordinates (origin top-left).
    /// The first screen in `NSScreen.screens` is always the primary display, the one with the menu bar.
    private func toAccessibility(_ rect: CGRect) -> CGRect {
        let primaryHeight: CGFloat = NSScreen.screens.first?.frame.height ?? rect.height
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The usable area of a screen (menu bar and Dock excluded), in Accessibility coordinates.
    private func usableArea(of screen: NSScreen) -> CGRect {
        toAccessibility(screen.visibleFrame)
    }

    /// The screen holding the window's center, falling back to the main screen.
    private func screenContaining(_ rect: CGRect) -> NSScreen {
        let center: CGPoint = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { toAccessibility($0.frame).contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The next screen in system order, or nil when there is only one.
    private func screenAfter(_ screen: NSScreen) -> NSScreen? {
        let screens: [NSScreen] = NSScreen.screens
        guard screens.count > 1, let index: Int = screens.firstIndex(of: screen) else { return nil }
        return screens[(index + 1) % screens.count]
    }
}

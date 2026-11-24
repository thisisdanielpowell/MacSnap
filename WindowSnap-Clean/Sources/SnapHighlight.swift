// SnapHighlight.swift
// Flashes an orange outline around a window right after WindowSnap snaps or arranges it,
// so it's easy to see where it landed. The outline is WindowSnap's own see-through window:
// clicks pass through it, it never takes focus, and it doesn't read or touch the other app.

import Cocoa

@MainActor
final class SnapHighlight {
    static let color: NSColor = .systemOrange
    static let borderWidth: CGFloat = 4
    /// Roughly how round macOS 26 window corners are. macOS doesn't share the exact value with apps,
    /// and windows with toolbars are rounder, so this is an approximation; raise it if the outline looks square.
    static let windowCornerRadius: CGFloat = 16
    /// How long the outline stays fully visible, then how long it takes to fade out.
    static let visibleSeconds: TimeInterval = 0.35
    static let fadeSeconds: TimeInterval = 0.35

    /// Outlines currently on screen; a new flash replaces them.
    private var panels: [NSPanel] = []
    /// Increases with every flash, so a fade from an older flash doesn't remove newer outlines.
    private var generation: Int = 0

    /// Outlines each frame, then fades the outlines out.
    /// - Parameter frames: Window frames in Accessibility coordinates (top-left origin of the primary display).
    func flash(_ frames: [CGRect]) {
        clear()
        generation += 1
        let current: Int = generation
        panels = frames.map { (frame: CGRect) -> NSPanel in makePanel(around: toCocoa(frame)) }
        for panel: NSPanel in panels { panel.orderFrontRegardless() }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                let fading: [NSPanel] = self.panels
                NSAnimationContext.runAnimationGroup({ (context: NSAnimationContext) in
                    context.duration = Self.fadeSeconds
                    for panel: NSPanel in fading { panel.animator().alphaValue = 0 }
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current else { return }
                        self.clear()
                    }
                })
            }
        }
    }

    private func clear() {
        for panel: NSPanel in panels { panel.orderOut(nil) }
        panels = []
    }

    /// A borderless, transparent, click-through panel with an orange rounded border, just outside the window.
    private func makePanel(around windowFrame: NSRect) -> NSPanel {
        let frame: NSRect = windowFrame.insetBy(dx: -Self.borderWidth, dy: -Self.borderWidth)
        let panel: NSPanel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let border: NSView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        border.wantsLayer = true
        border.layer?.borderColor = Self.color.cgColor
        border.layer?.borderWidth = Self.borderWidth
        // The outline sits just outside the window, so its corners are the window's radius plus the border,
        // drawn with Apple's continuous ("squircle") curve like macOS windows.
        border.layer?.cornerRadius = Self.windowCornerRadius + Self.borderWidth
        border.layer?.cornerCurve = .continuous
        panel.contentView = border
        return panel
    }

    /// Converts Accessibility coordinates (origin top-left of the primary display) to Cocoa (origin bottom-left).
    private func toCocoa(_ rect: CGRect) -> NSRect {
        let primaryHeight: CGFloat = NSScreen.screens.first?.frame.height ?? rect.maxY
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

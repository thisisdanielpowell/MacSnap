// SnapLayout.swift
// Pure window geometry: where a window goes for each action.
// No system calls and no state, so every result depends only on its inputs.

import CoreGraphics

/// A window placement the user can trigger from a hotkey.
enum SnapAction: Equatable, Sendable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case center, sixteenNine, nextDisplay
}

/// Computes target frames. All rectangles use Accessibility coordinates:
/// origin at the top-left corner of the primary display, y grows downward.
enum SnapLayout {
    /// Widths that Left and Right cycle through on repeated presses: 1/2, then 2/3, then 1/3.
    static let sideFractions: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]

    /// Share of the usable screen (width or height, whichever limits first) the 16:9 window fills.
    static let sixteenNineFill: CGFloat = 0.85

    /// Space, in points, between a snapped window and the screen edge, and between two snapped windows.
    static let gap: CGFloat = 8

    /// Returns where the window goes for an action on its current screen.
    /// - Parameters:
    ///   - action: The placement. `.nextDisplay` returns nil here; use `frameOnNextScreen`.
    ///   - current: The window's current frame.
    ///   - area: The usable area of the window's screen (menu bar and Dock excluded).
    ///   - cycleIndex: How many times Left or Right was pressed in a row on this window, starting at 0.
    /// - Returns: The target frame, or nil for `.nextDisplay`.
    static func frame(for action: SnapAction, current: CGRect, area: CGRect, cycleIndex: Int) -> CGRect? {
        // Snapped tiles are cut from the area shrunk by half a gap, then each tile is shrunk by half a gap.
        // That leaves a full gap at the screen edges and a full gap between any two neighboring tiles.
        let halfGap: CGFloat = gap / 2
        let grid: CGRect = area.insetBy(dx: halfGap, dy: halfGap)
        let sideWidth: CGFloat = (grid.width * sideFractions[cycleIndex % sideFractions.count]).rounded()
        // One rounded split line per axis, shared by both tiles on either side of it,
        // so the gap between neighbors stays exact even when the screen size is odd.
        let midX: CGFloat = grid.minX + (grid.width / 2).rounded()
        let midY: CGFloat = grid.minY + (grid.height / 2).rounded()

        let tile: CGRect
        switch action {
        case .left:
            tile = CGRect(x: grid.minX, y: grid.minY, width: sideWidth, height: grid.height)
        case .right:
            tile = CGRect(x: grid.maxX - sideWidth, y: grid.minY, width: sideWidth, height: grid.height)
        case .top:
            tile = CGRect(x: grid.minX, y: grid.minY, width: grid.width, height: midY - grid.minY)
        case .bottom:
            tile = CGRect(x: grid.minX, y: midY, width: grid.width, height: grid.maxY - midY)
        case .topLeft:
            tile = CGRect(x: grid.minX, y: grid.minY, width: midX - grid.minX, height: midY - grid.minY)
        case .topRight:
            tile = CGRect(x: midX, y: grid.minY, width: grid.maxX - midX, height: midY - grid.minY)
        case .bottomLeft:
            tile = CGRect(x: grid.minX, y: midY, width: midX - grid.minX, height: grid.maxY - midY)
        case .bottomRight:
            tile = CGRect(x: midX, y: midY, width: grid.maxX - midX, height: grid.maxY - midY)
        case .center:
            // Keep the window's size, shrunk only if it doesn't fit inside the screen's gap margin.
            let inner: CGRect = area.insetBy(dx: gap, dy: gap)
            let size: CGSize = CGSize(width: min(current.width, inner.width), height: min(current.height, inner.height))
            return centered(size, in: inner)
        case .sixteenNine:
            // The largest 16:9 size inside the fill share of the screen. The width is a multiple of 16,
            // so the height (width * 9 / 16) is a whole number and the ratio is exact on screen.
            let maxWidth: CGFloat = min(area.width * sixteenNineFill, area.height * sixteenNineFill * 16 / 9)
            let width: CGFloat = (maxWidth / 16).rounded(.down) * 16
            return centered(CGSize(width: width, height: width * 9 / 16), in: area)
        case .nextDisplay:
            return nil
        }
        return tile.insetBy(dx: halfGap, dy: halfGap)
    }

    /// Maps a window from one screen to another, keeping its relative position and size,
    /// and keeps it fully inside the new screen.
    /// - Parameters:
    ///   - current: The window's current frame.
    ///   - from: The usable area of the screen the window is on now.
    ///   - to: The usable area of the screen it moves to.
    /// - Returns: The window's frame on the new screen.
    static func frameOnNextScreen(_ current: CGRect, from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else {
            let size: CGSize = CGSize(width: min(current.width, to.width), height: min(current.height, to.height))
            return centered(size, in: to)
        }
        let scaleX: CGFloat = to.width / from.width
        let scaleY: CGFloat = to.height / from.height
        let width: CGFloat = min(current.width * scaleX, to.width)
        let height: CGFloat = min(current.height * scaleY, to.height)
        let x: CGFloat = to.minX + (current.minX - from.minX) * scaleX
        let y: CGFloat = to.minY + (current.minY - from.minY) * scaleY
        return CGRect(
            x: min(max(x, to.minX), to.maxX - width),
            y: min(max(y, to.minY), to.maxY - height),
            width: width,
            height: height
        )
    }

    // MARK: - Arranging several windows

    /// Layouts for 2, 3, and 4 windows, in the order Ctrl+Option+R cycles them.
    /// Each tile is a fraction of the usable screen (x, y, width, height, from the top-left),
    /// listed in the order the windows were picked.
    static let arrangements: [Int: [[CGRect]]] = [
        2: [
            // Halves
            [CGRect(x: 0, y: 0, width: 1.0 / 2, height: 1), CGRect(x: 1.0 / 2, y: 0, width: 1.0 / 2, height: 1)],
            // 2/3 + 1/3
            [CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1), CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)],
            // 1/3 + 2/3
            [CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)],
        ],
        3: [
            // Big left, two stacked right
            [CGRect(x: 0, y: 0, width: 1.0 / 2, height: 1),
             CGRect(x: 1.0 / 2, y: 0, width: 1.0 / 2, height: 1.0 / 2),
             CGRect(x: 1.0 / 2, y: 1.0 / 2, width: 1.0 / 2, height: 1.0 / 2)],
            // Three columns
            [CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1),
             CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
             CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)],
        ],
        4: [
            // Four corners
            [CGRect(x: 0, y: 0, width: 1.0 / 2, height: 1.0 / 2),
             CGRect(x: 1.0 / 2, y: 0, width: 1.0 / 2, height: 1.0 / 2),
             CGRect(x: 0, y: 1.0 / 2, width: 1.0 / 2, height: 1.0 / 2),
             CGRect(x: 1.0 / 2, y: 1.0 / 2, width: 1.0 / 2, height: 1.0 / 2)],
            // Big left, three stacked right
            [CGRect(x: 0, y: 0, width: 1.0 / 2, height: 1),
             CGRect(x: 1.0 / 2, y: 0, width: 1.0 / 2, height: 1.0 / 3),
             CGRect(x: 1.0 / 2, y: 1.0 / 3, width: 1.0 / 2, height: 1.0 / 3),
             CGRect(x: 1.0 / 2, y: 2.0 / 3, width: 1.0 / 2, height: 1.0 / 3)],
        ],
    ]

    /// How many layouts exist for a number of windows (0 if that number isn't supported).
    static func layoutCount(for windowCount: Int) -> Int {
        arrangements[windowCount]?.count ?? 0
    }

    /// Returns one frame per window for a multi-window layout, with the same gaps as snapping.
    /// - Parameters:
    ///   - windowCount: How many windows are being arranged (2 to 4).
    ///   - layout: Which layout for that count; wraps around.
    ///   - area: The usable area of the screen.
    /// - Returns: Frames in pick order, or an empty array if the count isn't supported.
    static func arrangement(windowCount: Int, layout: Int, area: CGRect) -> [CGRect] {
        guard let layouts: [[CGRect]] = arrangements[windowCount], !layouts.isEmpty else { return [] }
        let halfGap: CGFloat = gap / 2
        let grid: CGRect = area.insetBy(dx: halfGap, dy: halfGap)
        // Each edge is rounded once from its fraction, so two windows sharing an edge get exactly
        // the same line and the gap between them stays exact.
        let edgeX: (CGFloat) -> CGFloat = { (fraction: CGFloat) -> CGFloat in grid.minX + (grid.width * fraction).rounded() }
        let edgeY: (CGFloat) -> CGFloat = { (fraction: CGFloat) -> CGFloat in grid.minY + (grid.height * fraction).rounded() }
        return layouts[layout % layouts.count].map { (unit: CGRect) -> CGRect in
            let left: CGFloat = edgeX(unit.minX)
            let right: CGFloat = edgeX(unit.maxX)
            let top: CGFloat = edgeY(unit.minY)
            let bottom: CGFloat = edgeY(unit.maxY)
            return CGRect(x: left, y: top, width: right - left, height: bottom - top).insetBy(dx: halfGap, dy: halfGap)
        }
    }

    /// Centers a size inside an area, with the origin on whole points so the size isn't changed by rounding.
    private static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
}

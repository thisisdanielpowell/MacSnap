// LayoutTests.swift
// Checks the window geometry in SnapLayout.swift: gaps, sizes, and multi-window layouts.
// build.js compiles this together with Sources/SnapLayout.swift and runs it before building the app;
// any failure stops the build. Pure math, so it needs no permissions and moves no windows.

import CoreGraphics
import Foundation

/// Counts passed and failed checks, and prints each failure.
struct Tally {
    private(set) var passes: Int = 0
    private(set) var failures: Int = 0

    /// Checks a number. Values may differ by up to `tolerance` points for rounding.
    mutating func expect(_ name: String, _ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0) {
        record(name, abs(actual - expected) <= tolerance, detail: "got \(actual), expected \(expected)")
    }

    /// Checks a condition.
    mutating func expect(_ name: String, _ condition: Bool) {
        record(name, condition, detail: "condition was false")
    }

    private mutating func record(_ name: String, _ passed: Bool, detail: String) {
        if passed {
            passes += 1
        } else {
            failures += 1
            print("FAIL \(name): \(detail)")
        }
    }
}

@main
enum LayoutTests {
    /// A typical usable screen area (2056 x 1227 points, below a 39-point menu bar), in Accessibility coordinates.
    static let area: CGRect = CGRect(x: 0, y: 39, width: 2056, height: 1227)
    /// A window that isn't snapped yet.
    static let current: CGRect = CGRect(x: 300, y: 200, width: 900, height: 600)
    /// The intended gap, written out rather than read from SnapLayout, so a changed gap fails the tests.
    /// If you change `SnapLayout.gap` on purpose, change this to match.
    static let gap: CGFloat = 8

    static func main() {
        var t: Tally = Tally()
        checkSnaps(&t)
        checkNextDisplay(&t)
        checkArrangements(&t)
        print(t.failures == 0 ? "Layout tests: all \(t.passes) passed" : "Layout tests: \(t.failures) failed, \(t.passes) passed")
        exit(t.failures == 0 ? 0 : 1)
    }

    /// The frame SnapLayout gives an action, on whole points like the app uses.
    static func snap(_ action: SnapAction, cycle: Int = 0) -> CGRect {
        SnapLayout.frame(for: action, current: current, area: area, cycleIndex: cycle)?.integral ?? .null
    }

    /// Single-window snaps: gaps at every edge and between neighbors, cycling, center, 16:9.
    static func checkSnaps(_ t: inout Tally) {
        let left: CGRect = snap(.left)
        let right: CGRect = snap(.right)
        t.expect("left half: gap at left edge", left.minX - area.minX, gap)
        t.expect("left half: gap at top edge", left.minY - area.minY, gap)
        t.expect("left half: gap at bottom edge", area.maxY - left.maxY, gap)
        t.expect("right half: gap at right edge", area.maxX - right.maxX, gap)
        t.expect("gap between left and right halves", right.minX - left.maxX, gap)
        t.expect("gap between left 2/3 and right 1/3", snap(.right, cycle: 2).minX - snap(.left, cycle: 1).maxX, gap)
        t.expect("gap between left 1/3 and right 2/3", snap(.right, cycle: 1).minX - snap(.left, cycle: 2).maxX, gap)
        t.expect("gap between top and bottom halves", snap(.bottom).minY - snap(.top).maxY, gap)
        t.expect("gap between top-left and top-right", snap(.topRight).minX - snap(.topLeft).maxX, gap)
        t.expect("gap between top-left and bottom-left", snap(.bottomLeft).minY - snap(.topLeft).maxY, gap)
        t.expect("bottom-right: gap at right edge", area.maxX - snap(.bottomRight).maxX, gap)
        t.expect("bottom-right: gap at bottom edge", area.maxY - snap(.bottomRight).maxY, gap)
        t.expect("left cycles back to 1/2 after 1/3", snap(.left, cycle: 3).width, left.width)

        let centered: CGRect = snap(.center)
        t.expect("center keeps the window's width", centered.width, current.width)
        t.expect("center is centered", centered.midX, area.midX)

        let wide: CGRect = snap(.sixteenNine)
        t.expect("16:9 ratio (x1000)", (wide.width / wide.height * 1000).rounded(), (16.0 / 9.0 * 1000).rounded())
        t.expect("16:9 fits on screen", area.contains(wide))
        t.expect("next display returns nil from frame(for:)",
                 SnapLayout.frame(for: .nextDisplay, current: current, area: area, cycleIndex: 0) == nil)
    }

    /// Moving to another display keeps the window fully on the new screen.
    static func checkNextDisplay(_ t: inout Tally) {
        let secondScreen: CGRect = CGRect(x: 2056, y: 0, width: 1920, height: 1055)
        let moved: CGRect = SnapLayout.frameOnNextScreen(current, from: area, to: secondScreen)
        t.expect("next display: window lands fully on the new screen", secondScreen.contains(moved))
    }

    /// Every arrange layout: one frame per window, exact gaps, no overlaps.
    static func checkArrangements(_ t: inout Tally) {
        for count: Int in [2, 3, 4] {
            t.expect("\(count) windows: has layouts", SnapLayout.layoutCount(for: count) > 0)
            for layout: Int in 0..<SnapLayout.layoutCount(for: count) {
                let frames: [CGRect] = SnapLayout.arrangement(windowCount: count, layout: layout, area: area)
                let name: String = "\(count) windows, layout \(layout + 1)"
                t.expect("\(name): one frame per window", frames.count == count)
                for (i, frame): (Int, CGRect) in frames.enumerated() {
                    let others: [CGRect] = frames.enumerated().filter { $0.offset != i }.map { $0.element }
                    // Every edge is exactly one gap from the screen edge or from a neighbor.
                    t.expect("\(name), window \(i + 1): left edge gap",
                             frame.minX == area.minX + gap || others.contains { frame.minX - $0.maxX == gap })
                    t.expect("\(name), window \(i + 1): right edge gap",
                             frame.maxX == area.maxX - gap || others.contains { $0.minX - frame.maxX == gap })
                    t.expect("\(name), window \(i + 1): top edge gap",
                             frame.minY == area.minY + gap || others.contains { frame.minY - $0.maxY == gap })
                    t.expect("\(name), window \(i + 1): bottom edge gap",
                             frame.maxY == area.maxY - gap || others.contains { $0.minY - frame.maxY == gap })
                    for (j, other): (Int, CGRect) in frames.enumerated() where j > i {
                        t.expect("\(name): windows \(i + 1) and \(j + 1) don't overlap", !frame.intersects(other))
                    }
                }
            }
        }
        t.expect("unsupported window count returns no frames",
                 SnapLayout.arrangement(windowCount: 5, layout: 0, area: area).isEmpty)
    }
}

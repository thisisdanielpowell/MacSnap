// SwitcherPanel.swift
// The on-screen panel shared by the window switcher and the arrange picker: an optional hint line,
// an optional search field, and a list of rows (icon, title, detail line, optional indent and pick number).
// It only draws and forwards key presses; the controllers decide what it shows and what each key does.

import Cocoa

/// What one line of the panel shows. Controllers build these from windows and tabs.
struct PanelRow {
    /// App icon for a window row; nil for a tab row.
    let icon: NSImage?
    let title: String
    /// Smaller second line, like the app name.
    let detail: String
    /// Tab rows are indented under their window.
    var indented: Bool = false
    /// Pick number (1 to 4) in the arrange picker, or nil.
    var pick: Int? = nil
}

extension SwitcherItem {
    /// The panel row for this window: app icon, window title, app name.
    /// - Parameter tabCount: When known and more than one, shown after the app name.
    func panelRow(tabCount: Int? = nil, pick: Int? = nil) -> PanelRow {
        var detail: String = isMinimized ? "\(appName) (minimized)" : appName
        if let tabCount: Int, tabCount > 1 { detail += ", \(tabCount) tabs" }
        return PanelRow(icon: app.icon, title: title, detail: detail, pick: pick)
    }
}

extension TabItem {
    /// The panel row for this tab, indented under its window.
    var panelRow: PanelRow {
        PanelRow(icon: nil, title: title, detail: "Tab in \(owner.appName)", indented: true)
    }
}

@MainActor
final class SwitcherPanel: NSPanel {
    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 40
    /// Most rows shown at once; longer lists scroll to keep the selection visible.
    static let maxRows: Int = 12
    /// How solid the panel's background is, from 0 (only the frosted blur) to 1 (fully opaque).
    static let backgroundOpacity: CGFloat = 0.85
    private static let padding: CGFloat = 10

    /// The search box, shown only in search mode.
    let searchField: NSTextField = NSTextField()
    /// Called for each key pressed while the panel is focused. Returns true if the key was handled.
    var onKey: ((NSEvent) -> Bool)?

    private let hintLabel: NSTextField = NSTextField(labelWithString: "")
    private let rows: NSStackView = NSStackView()
    private let layout: NSStackView = NSStackView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                   styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        level = .modalPanel
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background: NSVisualEffectView = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        contentView = background

        // A tint over the blur so text stays readable over busy windows. NSBox follows light and dark mode.
        let tint: NSBox = NSBox()
        tint.boxType = .custom
        tint.borderWidth = 0
        tint.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(Self.backgroundOpacity)
        tint.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(tint)

        searchField.placeholderString = "Search windows and tabs"
        searchField.font = .systemFont(ofSize: 16)
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2

        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 8
        layout.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        layout.translatesAutoresizingMaskIntoConstraints = false
        layout.addArrangedSubview(hintLabel)
        layout.addArrangedSubview(searchField)
        layout.addArrangedSubview(rows)
        background.addSubview(layout)

        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tint.topAnchor.constraint(equalTo: background.topAnchor),
            tint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            layout.topAnchor.constraint(equalTo: background.topAnchor),
            layout.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            layout.widthAnchor.constraint(equalToConstant: Self.width),
            searchField.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.padding),
        ])
    }

    /// A borderless panel can't take keyboard focus by default; the panels need it for Tab, arrows, and search.
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }

    /// Redraws the list and centers the panel on the main screen.
    /// - Parameters:
    ///   - rows: The lines to show, in order.
    ///   - selected: Index of the highlighted line.
    ///   - searching: Whether to show the search field.
    ///   - hint: A line of instructions above the list, or nil for none.
    func show(rows content: [PanelRow], selected: Int, searching: Bool, hint: String? = nil) {
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil
        searchField.isHidden = !searching
        for view: NSView in rows.arrangedSubviews { view.removeFromSuperview() }

        let rowWidth: CGFloat = Self.width - 2 * Self.padding
        if content.isEmpty {
            rows.addArrangedSubview(NSTextField(labelWithString: searching ? "No matching windows or tabs" : "No windows"))
        } else {
            // Show up to maxRows lines, shifted so the selected line stays in view.
            let start: Int = max(0, min(selected - Self.maxRows / 2, content.count - Self.maxRows))
            let end: Int = min(content.count, start + Self.maxRows)
            for index: Int in start..<end {
                rows.addArrangedSubview(PanelRowView(row: content[index], selected: index == selected, width: rowWidth))
            }
        }

        layout.layoutSubtreeIfNeeded()
        setContentSize(layout.fittingSize)
        if let screen: NSScreen = NSScreen.main {
            let area: NSRect = screen.visibleFrame
            setFrameOrigin(NSPoint(x: (area.midX - frame.width / 2).rounded(), y: (area.midY - frame.height / 2).rounded()))
        }
    }
}

/// Draws one PanelRow: icon (or indent), title, detail underneath, and a pick number on the right.
@MainActor
private final class PanelRowView: NSView {
    private static let iconSize: CGFloat = 24
    private static let tabIndent: CGFloat = 34

    init(row: PanelRow, selected: Bool, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: SwitcherPanel.rowHeight))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor

        let title: NSTextField = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13, weight: row.indented ? .regular : .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail: NSTextField = NSTextField(labelWithString: row.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        if selected {
            title.textColor = .white
            detail.textColor = NSColor.white.withAlphaComponent(0.8)
        }

        let text: NSStackView = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        // The pick number (1 to 4) on the right, or nothing.
        let pickLabel: NSTextField = NSTextField(labelWithString: row.pick.map { String($0) } ?? "")
        pickLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        pickLabel.textColor = selected ? .white : .controlAccentColor
        pickLabel.alignment = .right

        var views: [NSView] = [text, pickLabel]
        var constraints: [NSLayoutConstraint] = []
        if let image: NSImage = row.icon {
            let icon: NSImageView = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyUpOrDown
            views.insert(icon, at: 0)
            constraints += [
                icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
                icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            ]
        }

        let line: NSStackView = NSStackView(views: views)
        line.orientation = .horizontal
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 0, left: row.indented ? Self.tabIndent + 8 : 8, bottom: 0, right: 8)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate(constraints + [
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: SwitcherPanel.rowHeight),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Rows are only created in code, never loaded from a file.
    required init?(coder: NSCoder) {
        return nil
    }
}

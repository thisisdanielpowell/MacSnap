// HotkeyCenter.swift
// Registers WindowSnap's global shortcuts with macOS (Carbon RegisterEventHotKey).
//
// Security: macOS delivers only the exact key combinations registered here, and only as a numeric ID.
// WindowSnap never receives, sees, or handles any other key press. No keyboard monitoring permission
// (Input Monitoring) is needed, and no event tap is used.

import Carbon.HIToolbox

/// What a shortcut does.
enum HotkeyCommand: Equatable, Sendable {
    /// Move or resize the focused window.
    case snap(SnapAction)
    /// Window switcher: open it, or move the highlight down.
    case switcherNext
    /// Window switcher: open it, or move the highlight up.
    case switcherPrevious
    /// Window switcher in search mode.
    case switcherSearch
    /// Arrange picker, or the next layout if pressed again within 3 seconds of arranging.
    case arrange
}

/// One global shortcut and the command it triggers.
struct Hotkey: Sendable {
    /// Carbon virtual key code, like `kVK_LeftArrow`.
    let keyCode: Int
    /// Carbon modifier flags, like `controlKey | optionKey`.
    let modifiers: Int
    /// What the shortcut does.
    let command: HotkeyCommand
    /// How the shortcut is shown in the menu and README.
    let label: String
}

/// Four-character tag ("WSNP") that marks hotkey events as WindowSnap's own.
private let hotkeySignature: OSType = 0x5753_4E50

@MainActor
final class HotkeyCenter {
    static let shared: HotkeyCenter = HotkeyCenter()

    /// Called on the main thread with the command for each registered shortcut press.
    var onHotkey: ((HotkeyCommand) -> Void)?

    private var registered: [EventHotKeyRef] = []
    private var commandsByID: [UInt32: HotkeyCommand] = [:]
    private var handler: EventHandlerRef?

    private init() {}

    /// Registers each shortcut with macOS.
    /// - Parameter hotkeys: The shortcuts to register.
    /// - Returns: Labels of any shortcuts macOS refused to register; those stay inactive.
    ///   macOS may accept a combination another app also uses, so an empty result doesn't rule out a clash.
    func register(_ hotkeys: [Hotkey]) -> [String] {
        installHandlerIfNeeded()
        var unavailable: [String] = []
        for (index, hotkey): (Int, Hotkey) in hotkeys.enumerated() {
            let id: UInt32 = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status: OSStatus = RegisterEventHotKey(
                UInt32(hotkey.keyCode),
                UInt32(hotkey.modifiers),
                EventHotKeyID(signature: hotkeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref: EventHotKeyRef {
                registered.append(ref)
                commandsByID[id] = hotkey.command
            } else {
                unavailable.append(hotkey.label)
            }
        }
        return unavailable
    }

    /// Runs the command for a registered shortcut ID.
    fileprivate func handle(id: UInt32) {
        guard let command: HotkeyCommand = commandsByID[id] else { return }
        onHotkey?(command)
    }

    /// Installs the single handler that receives "hotkey pressed" events for this app.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType: EventTypeSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyPressed, 1, &eventType, nil, &handler)
    }
}

/// Carbon calls this on the main thread when a registered shortcut is pressed.
/// It reads only the shortcut's ID; no key or character data is available to it.
private func hotkeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event: EventRef else { return OSStatus(eventNotHandledErr) }
    var hotkeyID: EventHotKeyID = EventHotKeyID()
    let status: OSStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr, hotkeyID.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
    let id: UInt32 = hotkeyID.id
    MainActor.assumeIsolated { HotkeyCenter.shared.handle(id: id) }
    return noErr
}

// AX.swift
// Small, type-checked wrappers around the macOS Accessibility API reads WindowSnap uses.
// Every read checks the value's type before using it, so a misbehaving app can't cause a crash.

import ApplicationServices

enum AX {
    /// Reads a raw attribute value, or nil if the app doesn't provide it.
    /// - Parameters:
    ///   - element: The app or window to read.
    ///   - name: The attribute name, like `kAXWindowsAttribute`.
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Reads several attributes in one request to the app, which is much faster than one request each
    /// when walking a large window. Missing attributes come back as nil, in the same order as `names`.
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let array: [AnyObject] = values as? [AnyObject],
              array.count == names.count
        else { return names.map { (_: String) -> CFTypeRef? in nil } }
        return array.map { (value: AnyObject) -> CFTypeRef? in
            // An attribute the element doesn't have comes back as an AXValue holding an error.
            if CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError {
                return nil
            }
            return value
        }
    }

    /// Reads an attribute that holds one element, like an app's focused window.
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        asElement(attribute(element, name))
    }

    /// Reads an attribute that holds a list of elements, like an app's windows. Non-elements are skipped.
    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        asElements(attribute(element, name))
    }

    /// Reads a text attribute, like a window's title.
    static func string(_ element: AXUIElement, _ name: String) -> String? {
        asString(attribute(element, name))
    }

    /// Reads a yes/no attribute, like whether a window is minimized.
    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value: CFTypeRef = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    /// Reads a point or size attribute (an AXValue).
    /// `T` is limited to plain values (`BitwiseCopyable`, like CGPoint and CGSize), so the raw copy is safe.
    /// - Parameters:
    ///   - element: The window to read.
    ///   - name: The attribute name, like `kAXPositionAttribute`.
    ///   - type: The AXValue type expected.
    ///   - empty: A starting value of the matching Swift type, filled in on success.
    static func value<T: BitwiseCopyable>(_ element: AXUIElement, _ name: String, type: AXValueType, empty: T) -> T? {
        guard let raw: CFTypeRef = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue: AXValue = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return nil }
        var result: T = empty
        return AXValueGetValue(axValue, type, &result) ? result : nil
    }

    // MARK: - Type-checked conversions

    /// The value as one element, if it is one.
    static func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value: CFTypeRef, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // The type ID check above proves this is an AXUIElement, so the downcast cannot fail.
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// The value as a list of elements; anything else in the list is skipped.
    static func asElements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value: CFTypeRef, CFGetTypeID(value) == CFArrayGetTypeID(), let array: [AnyObject] = value as? [AnyObject] else {
            return []
        }
        return array.compactMap { (item: AnyObject) -> AXUIElement? in asElement(item) }
    }

    /// The value as text, if it is text.
    static func asString(_ value: CFTypeRef?) -> String? {
        guard let value: CFTypeRef, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFString.self) as String
    }
}

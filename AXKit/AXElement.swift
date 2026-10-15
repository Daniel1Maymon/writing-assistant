import ApplicationServices
import Foundation

// Attribute names are written as literals: the kAX… constants are mutable globals, which Swift 6 rejects.

/// A thin wrapper around one Accessibility element of another app. Coordinates are AX screen
/// coordinates: origin at the top-left of the main screen, y growing down.
struct AXElement: Equatable, @unchecked Sendable {
    let ref: AXUIElement

    static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }

    static func application(_ pid: pid_t) -> AXElement { AXElement(ref: AXUIElementCreateApplication(pid)) }

    private func raw(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ name: String) -> AXElement? {
        guard let value = raw(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(ref: value as! AXUIElement)
    }

    private func axValue<T>(_ value: CFTypeRef?, _ type: AXValueType, _ empty: T) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = empty
        return AXValueGetValue(value as! AXValue, type, &result) ? result : nil
    }

    var role: String? { raw("AXRole") as? String }
    var subrole: String? { raw("AXSubrole") as? String }
    var value: String? { raw("AXValue") as? String }
    var parent: AXElement? { element("AXParent") }
    var window: AXElement? { element("AXWindow") }
    var focusedElement: AXElement? { element("AXFocusedUIElement") }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    var isSecure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }

    var frame: CGRect? {
        guard let origin = axValue(raw("AXPosition"), .cgPoint, CGPoint.zero),
              let size = axValue(raw("AXSize"), .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The caret (length 0) or the selection, as a UTF-16 range.
    var selectedRange: NSRange? {
        axValue(raw("AXSelectedTextRange"), .cfRange, CFRange()).map { NSRange(location: $0.location, length: $0.length) }
    }

    /// Screen rect of a UTF-16 range of the value.
    func bounds(for range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(ref, "AXBoundsForRange" as CFString, param, &value) == .success
        else { return nil }
        return axValue(value, .cgRect, CGRect.zero)
    }
}

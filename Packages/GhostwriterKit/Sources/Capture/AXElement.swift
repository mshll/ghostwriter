import ApplicationServices
import CoreGraphics
import Foundation
import GWCore
import os

struct AXFailure: Error {
    let code: AXError
}

/// `AXUIElementRef` is an immutable CF handle and the AX client API may be called from any thread.
struct AXElement: @unchecked Sendable, Hashable {
    static let messagingTimeout: Float = 0.25
    private static let log = Logger.gw("capture.ax")

    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
        let error = AXUIElementSetMessagingTimeout(ref, Self.messagingTimeout)
        if error != .success {
            Self.log.debug("AXUIElementSetMessagingTimeout failed: \(error.rawValue)")
        }
    }

    static func application(_ pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.ref, rhs.ref)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(ref))
    }

    var cfHash: UInt { CFHash(ref) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    func value(_ attribute: String) throws(AXFailure) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ref, attribute as CFString, &value)
        return try Self.check(error) ? value : nil
    }

    func values(_ attributes: [String]) throws(AXFailure) -> [String: CFTypeRef] {
        var array: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(ref, attributes as CFArray, [], &array)
        guard try Self.check(error), let items = array as? [AnyObject], items.count == attributes.count else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, item) in zip(attributes, items) where !Self.isErrorOrNull(item) {
            result[name] = item
        }
        return result
    }

    func parameterized(_ attribute: String, _ parameter: CFTypeRef) throws(AXFailure) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(ref, attribute as CFString, parameter, &value)
        return try Self.check(error) ? value : nil
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    func string(_ attribute: String) throws(AXFailure) -> String? {
        AXDecode.string(try value(attribute))
    }

    func element(_ attribute: String) throws(AXFailure) -> AXElement? {
        AXDecode.element(try value(attribute))
    }

    private static func check(_ error: AXError) throws(AXFailure) -> Bool {
        switch error {
        case .success:
            return true
        case .cannotComplete, .invalidUIElement, .apiDisabled:
            throw AXFailure(code: error)
        default:
            return false
        }
    }

    private static func isErrorOrNull(_ item: AnyObject) -> Bool {
        if CFGetTypeID(item) == CFNullGetTypeID() { return true }
        guard CFGetTypeID(item) == AXValueGetTypeID() else { return false }
        return AXValueGetType(unsafeDowncast(item, to: AXValue.self)) == .axError
    }
}

enum AXDecode {
    static func string(_ value: CFTypeRef?) -> String? {
        value as? String
    }

    static func nonEmptyString(_ value: CFTypeRef?) -> String? {
        guard let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func bool(_ value: CFTypeRef?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    static func int(_ value: CFTypeRef?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func strings(_ value: CFTypeRef?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func element(_ value: CFTypeRef?) -> AXElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    static func range(_ value: CFTypeRef?) -> CFRange? {
        var range = CFRange()
        return unpack(value, .cfRange, &range) ? range : nil
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        var rect = CGRect.zero
        return unpack(value, .cgRect, &rect) ? rect : nil
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        var point = CGPoint.zero
        return unpack(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        var size = CGSize.zero
        return unpack(value, .cgSize, &size) ? size : nil
    }

    static func url(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL { return url }
        return string(value).flatMap(URL.init(string:))
    }

    static func color(_ value: CFTypeRef?) -> CGColor? {
        guard let value, CFGetTypeID(value) == CGColor.typeID else { return nil }
        return unsafeDowncast(value, to: CGColor.self)
    }

    static func markerRange(_ value: CFTypeRef?) -> AXTextMarkerRange? {
        guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXTextMarkerRange.self)
    }

    static func marker(_ value: CFTypeRef?) -> AXTextMarker? {
        guard let value, CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXTextMarker.self)
    }

    static func rangeValue(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private static func unpack<T: BitwiseCopyable>(_ value: CFTypeRef?, _ type: AXValueType, _ out: inout T) -> Bool {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return false }
        return AXValueGetValue(axValue, type, &out)
    }
}

/// Attribute names not exported as Swift constants (private web attributes or `Unmanaged` imports).
enum AXName {
    static let language = "AXLanguage"
    static let userInputLabels = "AXUserInputLabels"
    static let domIdentifier = "AXDOMIdentifier"
    static let domClassList = "AXDOMClassList"
    static let valueAutofillType = "AXValueAutofillType"
    static let webAreaRole = "AXWebArea"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let fontText = "AXFont"
    static let fontName = "AXFontName"
    static let fontSize = "AXFontSize"
    static let fontBold = "AXFontBold"
    static let fontItalic = "AXFontItalic"
    static let foregroundColorText = "AXForegroundColor"
}

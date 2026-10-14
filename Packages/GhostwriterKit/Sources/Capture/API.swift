import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import GWCore

public enum IneligibleReason: Sendable, Hashable {
    case noFocusedElement
    case notTextInput
    case secureField
    case secureInputActive
    case tooSmall
    case addressBar
    case codeEditor
    case terminalShell
    case excludedApp
    case ownApp
    case searchField
    case excludedSite
    case excludedField
    case unreadable
}

public enum FocusEvent: Sendable, Hashable {
    case focused(FieldSnapshot)
    case changed(FieldSnapshot)
    case unfocused(AppIdentity?, IneligibleReason)
}

/// How one field read went. For tuning and the probe; contains no user text.
public struct ReadDiagnostics: Sendable, Hashable {
    public enum TextPath: String, Sendable {
        case value, stringForRange, textMarker, none
    }

    public enum CaretSource: String, Sendable {
        case previousCharacter, nextCharacter, collapsedRange, textMarker, estimate, none
    }

    public var bundleID: String
    public var duration: Duration
    public var textPath: TextPath
    public var caretSource: CaretSource
    public var reason: IneligibleReason?
}

public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    public static func request() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }
}

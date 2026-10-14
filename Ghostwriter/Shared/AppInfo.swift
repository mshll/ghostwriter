import AppKit
import UniformTypeIdentifiers

enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func url(for bundleID: String) -> URL? {
        if bundleID == Bundle.main.bundleIdentifier { return Bundle.main.bundleURL }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let name = url(for: bundleID).map { FileManager.default.displayName(atPath: $0.path).replacing(/\.app$/, with: "") } ?? bundleID
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let icon = url(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[bundleID] = icon
        return icon
    }
}

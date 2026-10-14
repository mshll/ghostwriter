import Foundation

public enum AppPaths {
    public static let bundleID = "com.mshl.ghostwriter"

    public static var support: URL {
        URL.applicationSupportDirectory.appending(path: bundleID, directoryHint: .isDirectory)
    }

    public static var models: URL {
        support.appending(path: "Models", directoryHint: .isDirectory)
    }

    public static var database: URL {
        support.appending(path: "ghostwriter.sqlite")
    }
}

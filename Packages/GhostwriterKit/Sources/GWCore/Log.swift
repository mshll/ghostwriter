import os

extension Logger {
    public static func gw(_ category: String) -> Logger {
        Logger(subsystem: AppPaths.bundleID, category: category)
    }
}

import AppKit
import GWCore
import os

enum Relauncher {
    private static let log = Logger.gw("Relauncher")

    // Some permissions apply only to a fresh process, so the app restarts itself.
    static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try reopen.run()
        } catch {
            log.error("Starting the relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}

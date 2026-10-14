import AppKit
import ApplicationServices
import Capture
import GWCore

/// Dev tool for the Capture module. Prints field text: never run it while typing anything private.
@main
@MainActor
enum Probe {
    static let started = ContinuousClock.now
    static var durations: [String: [Double]] = [:]

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        print("accessibility granted: \(AccessibilityPermission.isGranted), secure input: \(SecureInput.isEnabled)")
        switch arguments.first {
        case nil, "watch":
            watch(seconds: arguments.dropFirst().first.flatMap(Double.init))
        case "bench":
            bench(count: arguments.dropFirst().first.flatMap(Int.init) ?? 50,
                  delay: arguments.dropFirst(2).first.flatMap(Double.init) ?? 0.5)
        case "dump":
            AXTools.dumpFocused()
            return
        case "focus" where arguments.count >= 3:
            AXTools.focus(bundleID: arguments[1], domID: arguments[2], caret: arguments.dropFirst(3).first.flatMap(Int.init))
            return
        case "select" where arguments.count >= 2:
            AXTools.select(location: Int(arguments[1]) ?? 0, length: arguments.dropFirst(2).first.flatMap(Int.init) ?? 0)
            return
        default:
            print("usage: gw-axprobe [watch [seconds] | bench <count> [delay] | dump | focus <bundleID> <domID> [caret] | select <loc> [len]]")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.run()
    }

    static func watch(seconds: Double?) {
        let tracker = FocusTracker()
        tracker.onDiagnostics = record
        tracker.onEvent = { print(describe($0)) }
        tracker.start()
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    tracker.stop()
                    summarize()
                    exit(0)
                }
            }
        }
    }

    static func bench(count: Int, delay: Double) {
        let tracker = FocusTracker()
        tracker.onDiagnostics = record
        Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                print("cancelled: \(error)")
                exit(1)
            }
            var last: FieldSnapshot?
            for _ in 0..<count {
                last = await tracker.snapshot()
            }
            if let last { print(describe(.changed(last))) } else { print("no eligible field") }
            summarize()
            exit(0)
        }
    }

    static func record(_ diagnostics: ReadDiagnostics) {
        let ms = Double(diagnostics.duration.components.attoseconds) / 1e15 + Double(diagnostics.duration.components.seconds) * 1e3
        durations[diagnostics.bundleID, default: []].append(ms)
        let reason = diagnostics.reason.map { " reason=\($0)" } ?? ""
        print("  read \(diagnostics.bundleID) \(String(format: "%.2f", ms))ms text=\(diagnostics.textPath.rawValue) caret=\(diagnostics.caretSource.rawValue)\(reason)")
    }

    static func summarize() {
        for (bundleID, values) in durations.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))] }
            print(String(format: "summary %@ reads=%d p50=%.2fms p95=%.2fms max=%.2fms", bundleID, sorted.count,
                         percentile(0.5), percentile(0.95), sorted.last ?? 0))
        }
    }

    static func describe(_ event: FocusEvent) -> String {
        let elapsed = ContinuousClock.now - started
        let time = String(format: "+%.3fs", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        switch event {
        case .focused(let snapshot): return "\(time) FOCUSED \(describe(snapshot))"
        case .changed(let snapshot): return "\(time) CHANGED \(describe(snapshot))"
        case .unfocused(let app, let reason): return "\(time) UNFOCUSED \(app?.bundleID ?? "-") reason=\(reason)"
        }
    }

    static func describe(_ s: FieldSnapshot) -> String {
        let style = [s.style.fontName, s.style.fontSize.map { String(format: "%.1f", $0) }].compactMap { $0 }.joined(separator: " ")
        let color = s.style.textColor.map { String(format: "(%.2f,%.2f,%.2f,%.2f)", $0.red, $0.green, $0.blue, $0.alpha) } ?? "-"
        return """
        \(s.app.bundleID) kind=\(s.kind.rawValue) dir=\(s.direction == .rightToLeft ? "rtl" : "ltr") id=\(s.id.elementHash) label=\(quote(s.label)) \
        caret=\(rect(s.caretRect)) field=\(rect(s.fieldFrame)) font=\(style.isEmpty ? "-" : style) color=\(color) \
        window=\(quote(s.windowTitle)) url=\(s.url?.absoluteString ?? "-") lang=\(s.language ?? "-") midLine=\(s.isMidLine)
            before[\(s.textBefore.utf16.count)]=\(quote(String(s.textBefore.suffix(40)))) \
        after[\(s.textAfter.utf16.count)]=\(quote(String(s.textAfter.prefix(40)))) selected[\(s.selectedText.utf16.count)]
        """
    }

    static func quote(_ text: String?) -> String {
        guard let text else { return "-" }
        return "\"" + text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\u{00A0}", with: "⍽") + "\""
    }

    static func rect(_ r: CGRect) -> String {
        String(format: "{%.1f,%.1f %.1fx%.1f}", r.minX, r.minY, r.width, r.height)
    }
}

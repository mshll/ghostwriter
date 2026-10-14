import AppKit
import Input
import SwiftUI

struct HotKeyRecorder: View {
    private static let escapeKeyCode: UInt32 = 53

    @Binding var hotKey: HotKey
    @State private var isRecording = false
    @State private var monitor: Any?

    /// Sized like the shortcut recorders on the same page, so the two kinds line up.
    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press a key\u{2026}" : hotKey.displayName)
                .foregroundStyle(isRecording ? .secondary : .primary)
                .frame(width: 130, height: 24)
                .background(Color(nsColor: .textBackgroundColor), in: .capsule)
                .overlay(Capsule().strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.25)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the key to use, or click to cancel" : "Click, then press a key")
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let recorded = HotKey(event: event)
            if recorded != HotKey(keyCode: Self.escapeKeyCode) {
                hotKey = recorded
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

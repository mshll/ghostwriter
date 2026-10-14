import AppKit

enum SystemSettings {
    case accessibility, screenRecording, pasteboard, keyboard

    private var url: URL? {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .pasteboard: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
        case .keyboard: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        }
    }

    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

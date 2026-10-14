import AppKit
import Inference
import SwiftUI

final class WindowManager: NSObject, NSWindowDelegate {
    private static let settingsFrameName = "GhostwriterSettings"

    let settingsNavigation: SettingsNavigation
    var statusItemFrame: () -> NSRect? = { nil }

    private let preferences: Preferences
    private let appState: AppState
    private let services: AppServices
    private var settingsWindow: NSWindow?
    private var onboarding: OnboardingController?

    init(preferences: Preferences, appState: AppState, services: AppServices) {
        self.preferences = preferences
        self.appState = appState
        self.services = services
        settingsNavigation = SettingsNavigation(pane: preferences.settingsPane)
    }

    func showAppSettings(_ bundleID: String) {
        settingsNavigation.app = bundleID
        showSettings(.apps)
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsNavigation.pane = pane }
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = makeWindow(
            title: "Ghostwriter Settings",
            content: SettingsView(navigation: settingsNavigation)
                .environment(\.replayOnboarding) { [weak self] in self?.showOnboarding() },
            style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            autosaveName: nil
        )
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: SettingsView.width, height: 480)
        window.contentMaxSize = NSSize(width: SettingsView.width, height: .greatestFiniteMagnitude)
        window.collectionBehavior.insert(.fullScreenNone)
        if !window.setFrameUsingName(Self.settingsFrameName) {
            window.setContentSize(NSSize(width: SettingsView.width, height: 640))
            window.center()
        }
        window.setFrameAutosaveName(Self.settingsFrameName)
        return window
    }

    func showOnboarding(_ steps: [OnboardingStep] = OnboardingStep.allCases) {
        if let onboarding {
            onboarding.bringToFront()
            return
        }
        settingsWindow?.close()
        let model = OnboardingModel(steps: steps, appState: appState, library: services.models)
        let controller = OnboardingController(
            model: model, preferences: preferences, statusItemFrame: { [weak self] in self?.statusItemFrame() },
            content: environment(OnboardingView(model: model))
        )
        controller.onClose = { [weak self] in
            self?.preferences.hasCompletedOnboarding = true
            self?.preferences.onboardingStep = nil
            self?.onboarding = nil
        }
        onboarding = controller
        controller.present()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            settingsNavigation.pane = preferences.settingsPane
        }
        if settingsWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appState.refreshPermissions()
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    private func environment(_ content: some View) -> some View {
        content
            .environment(preferences)
            .environment(appState)
            .environment(services)
            .environment(services.models)
            .environment(services.appRules)
            .environment(services.snippets)
    }

    private func makeWindow(
        title: String, content: some View, style: NSWindow.StyleMask, autosaveName: String?
    ) -> NSWindow {
        let controller = NSHostingController(rootView: environment(content))
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = style
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }
        return window
    }
}

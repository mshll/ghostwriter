import AppKit
import GWCore
import Inference
import KeyboardShortcuts
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger.gw("AppDelegate")
    static let urlScheme = "ghostwriter"

    let preferences: Preferences
    let appState: AppState
    let services: AppServices
    let windows: WindowManager
    let selectionActions: SelectionActionsController

    private var statusItem: StatusItemController?
    private var coordinator: CompletionCoordinator?
    private var workspaceObserver: (any NSObjectProtocol)?
    private var shortcutTask: Task<Void, Never>?
    private var appShortcutTask: Task<Void, Never>?

    override init() {
        let preferences = Preferences()
        let appState = AppState()
        let services = AppServices(preferences: preferences, appState: appState)
        self.preferences = preferences
        self.appState = appState
        self.services = services
        windows = WindowManager(preferences: preferences, appState: appState, services: services)
        selectionActions = SelectionActionsController(preferences: preferences, assistant: services.assistant)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.refreshPermissions()
        services.refreshWordsToday(into: appState)
        trackFrontmostApp()
        let statusItem = StatusItemController(preferences: preferences, appState: appState, services: services, windows: windows)
        self.statusItem = statusItem
        windows.statusItemFrame = { [weak statusItem] in statusItem?.buttonScreenFrame }
        listenForToggleShortcut()
        startCompletionPipeline()

        if !preferences.hasCompletedOnboarding {
            windows.showOnboarding(OnboardingStep.from(preferences.onboardingStep ?? .welcome))
        } else if !appState.accessibilityGranted {
            windows.showOnboarding([.access])
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.stop()
        services.engine.cancel()
        Task { [engine = services.engine, downloader = services.downloader] in
            await downloader.suspendAll()
            await engine.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.showSettings() }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    func startCompletionPipeline() {
        let coordinator = CompletionCoordinator(
            preferences: preferences, appState: appState, services: services, selectionActions: selectionActions
        )
        coordinator.start()
        self.coordinator = coordinator
    }

    private func listenForToggleShortcut() {
        let switcher = SuggestionSwitch(preferences: preferences, appState: appState, appRules: services.appRules)
        shortcutTask = Task {
            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleCompletions) {
                switcher.toggleEverywhere()
            }
        }
        appShortcutTask = Task { [appState] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleCompletionsInApp) {
                guard let bundleID = appState.frontmostApp?.bundleID else { continue }
                switcher.toggle(in: bundleID)
            }
        }
    }

    private func trackFrontmostApp() {
        frontmostAppDidChange(NSWorkspace.shared.frontmostApplication)
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostAppDidChange(app) }
        }
    }

    private func frontmostAppDidChange(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier
        else { return }
        appState.frontmostApp = AppIdentity(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
    }

    private func handle(_ url: URL) {
        guard url.scheme == Self.urlScheme else { return }
        let argument = url.pathComponents.dropFirst().first
        switch url.host() {
        case "settings":
            windows.showSettings(argument.flatMap(SettingsPane.init(rawValue:)))
        case "onboarding":
            let first = argument.flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
            windows.showOnboarding(OnboardingStep.from(first))
        #if DEBUG
        case "debug-selection-actions":
            selectionActions.present(
                selectedText: "Thanks for getting back to me so quickly, I will look into it tomorrow morning.",
                near: .zero
            ) { text in
                Self.log.debug("Selection replacement: \(text.count) characters")
            }
        #endif
        default:
            Self.log.error("Unknown URL: \(url.host() ?? "", privacy: .public)")
        }
    }
}

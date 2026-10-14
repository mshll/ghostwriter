import AppKit
import Capture
import GWCore
import Inference
import KeyboardShortcuts
import Memory
import Observation
import os
import Sparkle

final class StatusItemController: NSObject, NSMenuDelegate {
    private static let log = Logger.gw("StatusItem")

    private struct IconState: Equatable, Sendable {
        var visible: Bool
        var dimmed: Bool
        var attention: Bool
        var count: Int?
    }

    private let preferences: Preferences
    private let appState: AppState
    private let services: AppServices
    private let windows: WindowManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var iconTask: Task<Void, Never>?

    private var switcher: SuggestionSwitch {
        SuggestionSwitch(preferences: preferences, appState: appState, appRules: services.appRules)
    }

    init(preferences: Preferences, appState: AppState, services: AppServices, windows: WindowManager) {
        self.preferences = preferences
        self.appState = appState
        self.services = services
        self.windows = windows
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        observeIconState()
    }

    var buttonScreenFrame: NSRect? {
        guard statusItem.isVisible, let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func observeIconState() {
        iconTask = Task { [weak self, preferences, appState] in
            let states = Observations {
                IconState(
                    visible: preferences.showsMenuBarIcon,
                    dimmed: appState.isGloballyPaused || !preferences.completionsEnabled,
                    attention: appState.needsAttention,
                    count: preferences.showWordCountInMenuBar && appState.wordsToday > 0 ? appState.wordsToday : nil
                )
            }
            for await state in states {
                self?.applyIcon(state)
            }
        }
    }

    private func applyIcon(_ state: IconState) {
        statusItem.isVisible = state.visible
        guard let button = statusItem.button else { return }
        button.image = Self.icon(attention: state.attention, count: state.count)
        button.appearsDisabled = state.dimmed
        button.toolTip = state.dimmed ? "Ghostwriter is paused" : "Ghostwriter"
    }

    private static func icon(attention: Bool, count: Int?) -> NSImage? {
        let glyph: NSImage
        if let count {
            glyph = CountGlyph.image(text: countText(count))
            glyph.accessibilityDescription = "Ghostwriter, \(count.formatted()) words saved today"
        } else if let asset = NSImage(named: "MenuBarIcon") {
            glyph = asset
            glyph.accessibilityDescription = "Ghostwriter"
        } else {
            log.error("MenuBarIcon asset is missing")
            return nil
        }
        guard attention else { return glyph }
        let badged = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = "Ghostwriter needs attention"
        return badged
    }

    private static func countText(_ count: Int) -> String {
        count < 10_000
            ? count.formatted()
            : count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    // Global shortcuts would fire after the menu closes, since the open menu holds their key presses.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.disable(KeyboardShortcuts.Name.global)
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.enable(KeyboardShortcuts.Name.global)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        appState.refreshPermissions()
        services.refreshWordsToday(into: appState)
        menu.removeAllItems()
        let showsExtras = NSEvent.modifierFlags.contains(.option)
        let app = appState.frontmostApp.flatMap { $0.bundleID == Bundle.main.bundleIdentifier ? nil : $0 }

        addIssueItems()
        addTodayItems()
        if !switcher.isOnEverywhere { addEverywhereItems() }
        if let app { addAppItems(for: app, showsExtras: showsExtras) }
        if switcher.isOnEverywhere { addEverywhereItems() }

        menu.addItem(.separator())
        let settings = actionItem("Settings\u{2026}", #selector(openSettings))
        settings.keyEquivalent = ","
        if #available(macOS 27, *) { settings.preferredImageVisibility = .hidden }
        menu.addItem(settings)
        if showsExtras {
            let updates = actionItem("Check for Updates\u{2026}", #selector(checkForUpdates))
            updates.isEnabled = services.updaterController.updater.canCheckForUpdates
            menu.addItem(updates)
            menu.addItem(actionItem("Copy Diagnostics", #selector(copyDiagnostics)))
        }
        let quit = actionItem("Quit Ghostwriter", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func addIssueItems() {
        for issue in appState.attentionIssues {
            let item = actionItem(issue.title, #selector(resolveIssue(_:)), represented: issue.kind.rawValue)
            item.image = NSImage(
                systemSymbolName: issue.severity == .info ? "info.circle" : "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )
            menu.addItem(item)
        }
        if let version = appState.availableUpdate {
            let item = actionItem("Install Update \(version)\u{2026}", #selector(checkForUpdates))
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            item.isEnabled = services.updaterController.updater.canCheckForUpdates
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
    }

    private func addTodayItems() {
        let words = appState.wordsToday
        let title = switch words {
        case 0: "No words written yet today"
        case 1: "1 word written today"
        default: "\(words.formatted()) words written today"
        }
        menu.addItem(actionItem(title, #selector(openStatistics)))
        for spec in services.models.downloadingModels {
            let progress = services.models.downloadProgress[spec.id] ?? 0
            menu.addItem(infoItem("Downloading \(spec.displayName): \(progress.formatted(.percent.precision(.fractionLength(0))))"))
        }
    }

    private func addEverywhereItems() {
        menu.addItem(.separator())
        if switcher.isOnEverywhere {
            let item = NSMenuItem(title: "Pause Everywhere", action: nil, keyEquivalent: "")
            item.submenu = offMenu(#selector(turnOffEverywhere(_:)), bundleID: nil, untilTitle: "Until I Turn It On")
            menu.addItem(item)
        } else {
            let status = preferences.completionsEnabled
                ? appState.globalPause.map { $0.summary(scope: "everywhere") } ?? "Paused everywhere"
                : "Suggestions are off everywhere"
            menu.addItem(infoItem(status))
            let item = actionItem("Turn On Everywhere", #selector(turnOnEverywhere))
            showShortcut(.toggleCompletions, on: item)
            menu.addItem(item)
        }
    }

    private func addAppItems(for app: AppIdentity, showsExtras: Bool) {
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: app.name))
        // Password managers are always off, so there is nothing to change.
        if BuiltInAppRules.rule(for: app.bundleID)?.recordWriting == false {
            menu.addItem(infoItem("Ghostwriter never runs here"))
            return
        }

        if switcher.isOn(in: app.bundleID) {
            let item = NSMenuItem(title: "Turn Off", action: nil, keyEquivalent: "")
            item.submenu = offMenu(#selector(turnOffInApp(_:)), bundleID: app.bundleID, untilTitle: "Until I Turn Them On")
            item.isEnabled = switcher.isOnEverywhere
            menu.addItem(item)
        } else {
            let status = appState.appPauses[app.bundleID].flatMap { $0.isActive ? $0.summary(scope: "here") : nil }
            menu.addItem(infoItem(status ?? "Suggestions are off here"))
            menu.addItem(actionItem("Turn On", #selector(turnOnInApp(_:)), represented: app.bundleID))
        }

        let rule = services.appRules.effectiveRule(for: app.bundleID)
        let tab = actionItem("Accept with Tab", #selector(toggleTabAccept(_:)), represented: app.bundleID)
        tab.state = rule.tabAcceptEnabled != false ? .on : .off
        menu.addItem(tab)
        if preferences.recordWriting {
            let record = actionItem("Learn from My Writing", #selector(toggleRecording(_:)), represented: app.bundleID)
            record.state = services.appRules.isRecordingAllowed(for: app.bundleID) ? .on : .off
            menu.addItem(record)
        }
        menu.addItem(actionItem("App Settings\u{2026}", #selector(openAppSettings(_:)), represented: app.bundleID))
        if showsExtras, preferences.recordWriting {
            menu.addItem(actionItem("Erase Writing from \(app.name)\u{2026}", #selector(eraseWriting(_:)), represented: app))
        }
    }

    private func offMenu(_ action: Selector, bundleID: String?, untilTitle: String) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, duration) in PauseDuration.allCases.enumerated() {
            let item = actionItem(duration.title, action, represented: bundleID)
            item.tag = index
            if bundleID != nil, duration == .fifteenMinutes { showShortcut(.toggleCompletionsInApp, on: item) }
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let until = actionItem(untilTitle, action, represented: bundleID)
        until.tag = -1
        if bundleID == nil { showShortcut(.toggleCompletions, on: until) }
        submenu.addItem(until)
        return submenu
    }

    private func showShortcut(_ name: KeyboardShortcuts.Name, on item: NSMenuItem) {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name), let key = shortcut.nsMenuItemKeyEquivalent else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        item.isEnabled = true
        return item
    }

    private static func duration(of item: NSMenuItem) -> PauseDuration? {
        PauseDuration.allCases.indices.contains(item.tag) ? PauseDuration.allCases[item.tag] : nil
    }

    @objc private func turnOffEverywhere(_ sender: NSMenuItem) {
        switcher.turnOffEverywhere(for: Self.duration(of: sender))
    }

    @objc private func turnOnEverywhere() {
        switcher.turnOnEverywhere()
    }

    @objc private func turnOffInApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        switcher.turnOff(in: bundleID, for: Self.duration(of: sender))
    }

    @objc private func turnOnInApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        switcher.turnOn(in: bundleID)
    }

    @objc private func toggleTabAccept(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        services.appRules.setTabAccept(sender.state == .off, for: bundleID)
    }

    @objc private func toggleRecording(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        services.appRules.setRecordWriting(sender.state == .off, for: bundleID)
    }

    @objc private func openAppSettings(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        windows.showAppSettings(bundleID)
    }

    @objc private func eraseWriting(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppIdentity else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Erase your writing recorded in \(app.name)?"
        alert.informativeText = "Ghostwriter stops recording in \(app.name) and deletes what it has stored from it. This can't be undone."
        alert.addButton(withTitle: "Stop and Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        services.appRules.setRecordWriting(false, for: app.bundleID)
        do {
            try services.memory?.eraseWriting(bundleID: app.bundleID)
        } catch {
            Self.log.error("Erasing writing for \(app.bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    @objc private func resolveIssue(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = AttentionIssue.Kind(rawValue: raw) else { return }
        switch kind {
        case .accessibility:
            windows.showOnboarding([.access])
        case .noModel, .modelFailed:
            windows.showSettings(.model)
        case .macOSPredictions:
            SystemSettings.keyboard.open()
        case .foundationModelsUnavailable:
            windows.showSettings(.selectionActions)
        case .databaseUnavailable:
            windows.showSettings(.privacy)
        case .secureInput:
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Secure Input is on"
            alert.informativeText = """
                Another app turned on macOS Secure Input, which blocks Ghostwriter's keys. \
                It is usually a password manager or a password field that is still open. \
                Quit that app, or lock and unlock your Mac, to turn it off.
                """
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        windows.showSettings()
    }

    @objc private func openStatistics() {
        windows.showSettings(.statistics)
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            Diagnostics.report(preferences: preferences, appState: appState, models: services.models), forType: .string
        )
    }

    @objc private func checkForUpdates() {
        NSApp.activate()
        services.updaterController.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

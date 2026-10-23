import Actions
import AppKit
import Capture
import GWCore
import Inference
import Input
import KeyboardShortcuts
import Memory
import Overlay
import Prompting
import Proofing
import ScreenContext
import os

final class CompletionCoordinator {
    nonisolated private static let log = Logger.gw("Coordinator")
    private static let typingWindow: Duration = .milliseconds(1500)
    private static let deletePause: Duration = .milliseconds(400)
    private static let autoSelectionDelay: Duration = .milliseconds(350)
    private static let briefPause: Duration = .seconds(4)
    private static let draftWords = 80
    private static let examplesRefreshCharacters = 400
    private static let contextReloadAge: Duration = .seconds(10)
    private static let biasStrengths: [Double] = [0, 0.5, 1, 1.5, 2, 3]
    private static let exampleLimits = [0, 1, 2, 2, 3, 4]
    private static let proofreadLimit = 3000
    private static let noticeDuration: Duration = .seconds(4)
    private static let autoFixUndoWindow: Duration = .seconds(5)
    private static let knownWordSessions = 3
    private static let maxSentenceTypos = 6
    /// Languages where `gw-eval --typos` measured automatic fixes as right about 98% of the time.
    private static let autoFixLanguages: Set<String> = ["en", "fr", "de", "es"]
    private static let proofreadPrewarmInterval: Duration = .seconds(300)

    private let preferences: Preferences
    private let appState: AppState
    private let services: AppServices
    private let selectionActions: SelectionActionsController

    private let tracker = FocusTracker()
    private let keys = KeyMonitor()
    private let hotKeys = HotKeyCenter()
    private let overlay = GhostOverlay()
    private let screen = ScreenContextProvider()
    private let power = PowerMonitor()
    private let models: ModelController
    private let recorder: WritingRecorder

    private var field: FieldSnapshot?
    private var context: SessionContext?
    private var contextTask: Task<SessionContext, Never>?
    private var suggestion: ActiveSuggestion?
    private var deferred: ActiveSuggestion?
    private var suggestionUsed = false
    private var emoji: (query: String, choices: [String])?
    private var registeredKeys: Set<HotKey> = []
    private var inFlight: (id: Int, mode: CompletionRequest.Mode, task: Task<Void, Never>)?
    private var lastInline: (field: FieldID, textBefore: String, textAfter: String)?
    private var generationCount = 0
    private var refresh: Task<Void, Never>?
    private var autoSelectionTask: Task<Void, Never>?
    private var autoShownSelection: String?
    private var pointerMovedLast = false
    private var insertion: Task<Void, Never>?
    private var lastTyping: ContinuousClock.Instant?
    private var pausedUntil: ContinuousClock.Instant?
    private var typedTail = ""
    private var typedSinceRead = ""
    private var editedSinceRead = false
    private var deleteSettle: Task<Void, Never>?
    private var charactersSinceExamples = 0
    private var acceptWatchdog: Task<Void, Never>?
    private var followers: (language: String?, value: [String: [String: Double]])?
    private var monitorsStarted = false
    private var permissionTimer: Timer?
    private var shortcutTasks: [Task<Void, Never>] = []
    private var proofreading: Task<Void, Never>?
    private var lastProofread: (field: FieldID, result: Proofread)?
    private var notice: Task<Void, Never>?
    private let typoJudge = TypoJudge()
    private var typoCheck: Task<Void, Never>?
    private var autoFixUndo: (field: FieldID, edit: Proofread, word: String, expiry: Task<Void, Never>)?
    private var lastProofreadPrewarm: ContinuousClock.Instant?

    init(preferences: Preferences, appState: AppState, services: AppServices, selectionActions: SelectionActionsController) {
        self.preferences = preferences
        self.appState = appState
        self.services = services
        self.selectionActions = selectionActions
        models = ModelController(services: services, appState: appState, preferences: preferences, power: power)
        recorder = WritingRecorder(memory: services.memory)
    }

    func start() {
        recorder.isAllowed = { [weak self] snapshot in self?.mayRecord(snapshot) ?? false }
        tracker.ruleProvider = { [weak self] key in self?.rule(forKey: key) }
        tracker.onEvent = { [weak self] event in self?.handle(event) }
        keys.onKey = { [weak self] event in self?.handleKey(event) }
        keys.onPointer = { [weak self] in self?.pointerMoved() }
        power.onChange = { [weak self] in self?.models.reconcile() }
        BackgroundSampling.isAllowed = { [weak self] in self?.preferences.ocrEnabled ?? false }
        power.start()
        models.start()
        ClipboardReader.startMonitoring()
        if preferences.ocrEnabled, appState.screenRecordingGranted {
            Task { await ScreenContextProvider.prewarmOCR() }
        }
        listenForShortcuts()
        followFeatureShortcuts()
        followPracticeField()
        startMonitorsWhenTrusted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMonitorsWhenTrusted() }
        }
    }

    func stop() {
        recorder.finish()
        hideAll()
        cancelGeneration()
        tracker.stop()
        permissionTimer?.invalidate()
        shortcutTasks.forEach { $0.cancel() }
    }

    // MARK: Monitors and shortcuts

    /// A turned-off feature must not keep its shortcut: the key combination would be swallowed system-wide.
    private func followFeatureShortcuts() {
        withObservationTracking {
            setShortcut(.longDraft, enabled: preferences.draftEnabled)
            setShortcut(.selectionActions, enabled: preferences.selectionActionsEnabled && appState.foundationModelsUnavailableReason == nil)
            setShortcut(.proofread, enabled: preferences.proofreadEnabled && appState.foundationModelsUnavailableReason == nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followFeatureShortcuts() }
        }
    }

    private func setShortcut(_ name: KeyboardShortcuts.Name, enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(name)
        } else {
            KeyboardShortcuts.disable(name)
        }
    }

    private func followPracticeField() {
        withObservationTracking {
            tracker.includesOwnApp = appState.practiceFieldVisible
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPracticeField() }
        }
    }

    private func startMonitorsWhenTrusted() {
        appState.refreshPermissions()
        guard appState.accessibilityGranted, !monitorsStarted else { return }
        monitorsStarted = keys.start()
        guard monitorsStarted else {
            Self.log.error("The key monitor could not start")
            return
        }
        tracker.start()
        Self.log.info("Completion pipeline started")
    }

    private func listenForShortcuts() {
        let bindings: [(KeyboardShortcuts.Name, @MainActor @Sendable () -> Void)] = [
            (.forceComplete, { [weak self] in self?.forceComplete() }),
            (.longDraft, { [weak self] in self?.requestDraft() }),
            (.selectionActions, { [weak self] in self?.presentSelectionActions() }),
            (.proofread, { [weak self] in self?.proofread() }),
        ]
        shortcutTasks = bindings.map { name, action in
            Task {
                for await _ in KeyboardShortcuts.events(.keyDown, for: name) {
                    action()
                }
            }
        }
    }

    // MARK: Field events

    private func handle(_ event: FocusEvent) {
        switch event {
        case .focused(let snapshot), .changed(let snapshot):
            if field?.id == snapshot.id {
                textChanged(snapshot)
            } else {
                focusMoved(to: snapshot)
            }
        case .unfocused:
            leaveField()
        }
    }

    private func focusMoved(to snapshot: FieldSnapshot) {
        leaveField()
        field = snapshot
        appState.lastFieldApp = snapshot.app
        recorder.begin(snapshot)
        loadContext(for: snapshot)
        if preferences.midLineEnabled {
            overlay.prepareBackground(for: snapshot)
        }
        prewarmProofreading()
    }

    private func leaveField() {
        recorder.finish()
        autoSelectionTask?.cancel()
        typoCheck?.cancel()
        clearAutoFixUndo()
        endDeleting()
        if selectionActions.isPassive { selectionActions.dismiss() }
        hideAll()
        cancelGeneration()
        field = nil
        context = nil
        contextTask?.cancel()
        contextTask = nil
        typedTail = ""
        typedSinceRead = ""
        editedSinceRead = false
    }

    private func textChanged(_ snapshot: FieldSnapshot) {
        guard snapshot != field else { return }
        settleTyped(against: snapshot)
        // The read does not show everything typed or inserted yet (apps report late, long accepts go in chunks).
        // The suggestion already follows that text and the engine has it or gets it from the next read, so a
        // request for this shorter text would only send the engine back.
        let lagging = !typedSinceRead.isEmpty
        let titleChanged = snapshot.windowTitle != field?.windowTitle
        let sameText = field.map {
            $0.id == snapshot.id && $0.textBefore == snapshot.textBefore && $0.textAfter == snapshot.textAfter
                && $0.selectedText == snapshot.selectedText
        } ?? false
        let selectionChanged = field?.selectedText != snapshot.selectedText
        field = snapshot
        if appState.isPaused(bundleID: snapshot.app.bundleID) {
            hideAll()
            cancelGeneration()
            return
        }
        if selectionChanged {
            selectionMoved(in: snapshot)
        }
        recorder.update(snapshot)
        if titleChanged, let context, ContinuousClock.now - context.loadedAt > Self.contextReloadAge {
            // Recent contexts are kept: titles also change with edit markers right after focus.
            Self.log.info("Reloading context: the window title changed")
            loadContext(for: snapshot)
        }
        if let current = suggestion {
            if snapshot.selectedText.isEmpty, var next = current.advanced(to: snapshot.textBefore + typedSinceRead) {
                guard !lagging else { return }
                if let later = deferred?.advanced(to: snapshot.textBefore),
                   ShownSuggestion.normalized(later.text).hasPrefix(ShownSuggestion.normalized(next.text)) {
                    next = later
                }
                deferred = nil
                show(next, in: snapshot)
                // The engine follows the typed text through its beams, so the phrase can grow as the user types into it.
                if next.kind == .completion, isTyping, !power.prefersEconomy {
                    refreshExamplesIfNeeded(for: snapshot)
                    requestCompletion(for: snapshot)
                }
                return
            }
            hideSuggestion()
        }
        guard !lagging else { return }
        guard isTyping else {
            // A read that only moves the caret rect, style or title keeps the request for this text, such as one
            // asked for on demand.
            guard !sameText else { return }
            hidePicker()
            detachSuggestions()
            return
        }
        if showEmojiPickerIfNeeded(for: snapshot) || deleteSettle != nil || checkTyposIfNeeded(for: snapshot) {
            cancelGeneration()
            return
        }
        refreshExamplesIfNeeded(for: snapshot)
        requestCompletion(for: snapshot)
    }

    private func settleTyped(against snapshot: FieldSnapshot) {
        defer { editedSinceRead = false }
        guard !typedSinceRead.isEmpty, !editedSinceRead, let previous = field, previous.id == snapshot.id,
              let appended = TextContinuation.appended(from: previous.textBefore, to: snapshot.textBefore),
              typedSinceRead.hasPrefix(appended)
        else {
            typedSinceRead = ""
            return
        }
        typedSinceRead.removeFirst(appended.count)
    }

    private var isTyping: Bool {
        guard let lastTyping else { return false }
        return ContinuousClock.now - lastTyping < Self.typingWindow
    }

    // MARK: Keys

    private func handleKey(_ event: KeyEvent) {
        let pressed = HotKey(keyCode: event.keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: event.modifiers))
        guard !registeredKeys.contains(pressed) else { return }
        pointerMovedLast = false
        hideNotice()
        clearAutoFixUndo()
        if event.kind != .other {
            endDeleting()
        }
        if selectionActions.isPassive {
            selectionActions.dismiss()
        }
        switch event.kind {
        case .character:
            lastTyping = .now
            typedSinceRead += event.characters
            typedTail = String((typedTail + event.characters).suffix(64))
            charactersSinceExamples += event.characters.count
            followTypedCharacters(event.characters)
            expandSnippetIfNeeded()
            scheduleRefresh()
        case .deleteBackward, .deleteForward:
            lastTyping = .now
            editedSinceRead = true
            typedTail = String(typedTail.dropLast())
            hideSuggestion()
            if let current = emoji, !current.query.isEmpty {
                emoji?.query = String(current.query.dropLast())
            } else {
                hidePicker()
            }
            scheduleRefresh()
            settleAfterDeleting()
        case .returnKey, .tab:
            typedTail = ""
            editedSinceRead = true
            scheduleRefresh()
        case .escape:
            proofreading?.cancel()
            hideAll()
            cancelGeneration()
        case .navigation, .shortcut:
            typedTail = ""
            lastTyping = nil
            hideAll()
            cancelGeneration()
            scheduleRefresh(after: .milliseconds(60))
        case .other:
            break
        }
    }

    /// Accept keys can fire before the field read that follows a keystroke, so the suggestion and the
    /// emoji query follow typed characters right away.
    private func followTypedCharacters(_ characters: String) {
        if let current = suggestion {
            if let next = current.advanced(to: current.anchor + characters) {
                suggestion = next
            } else {
                hideSuggestion()
            }
        }
        if let current = emoji {
            if characters.allSatisfy({ EmojiIndex.isQueryCharacter($0) }) {
                emoji?.query = current.query + characters
            } else {
                hidePicker()
            }
        }
    }

    private func settleAfterDeleting() {
        deleteSettle = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.deletePause)
            } catch {
                return
            }
            guard let self else { return }
            deleteSettle = nil
            guard let field else { return }
            if showEmojiPickerIfNeeded(for: field) || checkTyposIfNeeded(for: field) {
                cancelGeneration()
                return
            }
            refreshExamplesIfNeeded(for: field)
            requestCompletion(for: field)
        }
    }

    private func endDeleting() {
        deleteSettle?.cancel()
        deleteSettle = nil
    }

    private func pointerMoved() {
        pointerMovedLast = true
        endDeleting()
        guard field != nil else { return }
        typedTail = ""
        lastTyping = nil
        hideAll()
        cancelGeneration()
        scheduleRefresh(after: .milliseconds(80))
    }

    /// Re-reads the field after a keystroke or an accept, for apps that report text changes late or not at all.
    private func scheduleRefresh(after delay: Duration = .milliseconds(15), afterInsertion: Bool = false) {
        refresh?.cancel()
        let pending = afterInsertion ? insertion : nil
        refresh = Task { [weak self, tracker] in
            await pending?.value
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let snapshot = await tracker.snapshot(), !Task.isCancelled else { return }
            self?.handle(.changed(snapshot))
        }
    }

    // MARK: Generation

    /// Inline text changes replace the running request without cancelling the engine: it keeps whatever of its
    /// search still fits the new text.
    private func requestCompletion(for snapshot: FieldSnapshot, mode: CompletionRequest.Mode = .inline, forced: Bool = false) {
        guard mayComplete(snapshot, forced: forced) else {
            cancelGeneration()
            return
        }
        if mode == .inline, !forced, let last = lastInline, last.field == snapshot.id, last.textBefore == snapshot.textBefore,
           last.textAfter == snapshot.textAfter {
            return
        }
        if forced || mode == .draft || inFlight?.mode == .draft {
            cancelGeneration()
        } else {
            detachSuggestions()
        }
        startGeneration(for: snapshot, mode: mode, forced: forced)
    }

    private func startGeneration(for snapshot: FieldSnapshot, mode: CompletionRequest.Mode, forced: Bool) {
        let delay: Duration = forced ? .zero : BuiltInAppRules.isTerminal(snapshot.app.bundleID) ? .milliseconds(30) : .milliseconds(5)
        generationCount += 1
        let id = generationCount
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.generate(for: snapshot, mode: mode, id: id, forced: forced)
            self?.generationFinished(id)
        }
        inFlight = (id, mode, task)
        lastInline = mode == .inline ? (snapshot.id, snapshot.textBefore, snapshot.textAfter) : nil
    }

    private func generationFinished(_ id: Int) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }

    private func cancelGeneration() {
        lastInline = nil
        guard let inFlight else { return }
        inFlight.task.cancel()
        self.inFlight = nil
        services.engine.cancel()
    }

    private func detachSuggestions() {
        lastInline = nil
        guard let inFlight, inFlight.mode == .inline else { return }
        inFlight.task.cancel()
        self.inFlight = nil
    }

    private func generate(for snapshot: FieldSnapshot, mode: CompletionRequest.Mode, id: Int, forced: Bool) async {
        guard let builder = models.builder else { return }
        let keystroke = lastTyping
        let started = ContinuousClock.now
        let sessionContext = await currentContext()
        let contextReady = ContinuousClock.now
        guard !Task.isCancelled else { return }
        let midLine = snapshot.isMidLine
        let prompt = await buildPrompt(for: snapshot, context: sessionContext, mode: mode, builder: builder)
        let request = CompletionRequest(
            prompt: prompt.text,
            partialWord: prompt.partialWord,
            textAfter: midLine ? Self.restOfLine(snapshot.textAfter) : "",
            maxWords: mode == .draft ? Self.draftWords : maxWords,
            mode: mode,
            bias: await bias(for: prompt.language),
            stopStrings: BuiltPrompt.stopStrings
        )
        guard !Task.isCancelled else { return }
        let promptReady = ContinuousClock.now
        if mode == .inline {
            await streamSuggestions(for: request, from: snapshot, keystroke: keystroke, preparation: promptReady - started, forced: forced)
            return
        }
        var onPartial: (@Sendable (String) -> Void)?
        if mode == .draft {
            onPartial = { [weak self] partial in
                Task { @MainActor in self?.showDraftProgress(partial, from: snapshot, generation: id) }
            }
        }
        do {
            let candidates = try await services.engine.complete(request, onPartial: onPartial)
            let done = ContinuousClock.now
            let stats = await services.engine.lastStats
            Self.log.info("Timing ms: context \(Self.ms(contextReady - started), privacy: .public), prompt \(Self.ms(promptReady - contextReady), privacy: .public), engine \(Self.ms(done - promptReady), privacy: .public) (prefill \(Int(stats.prefillMilliseconds), privacy: .public), search \(Int(stats.searchMilliseconds), privacy: .public), rerank \(Int(stats.rerankMilliseconds), privacy: .public)), tokens \(stats.reusedTokens, privacy: .public)/\(stats.promptTokens, privacy: .public) reused, \(candidates.count, privacy: .public) candidates")
            guard !Task.isCancelled else { return }
            present(candidates.map(\.text), from: snapshot, kind: mode == .draft ? .draft : .completion, settled: true)
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Completion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func streamSuggestions(
        for request: CompletionRequest, from snapshot: FieldSnapshot, keystroke: ContinuousClock.Instant?, preparation: Duration,
        forced: Bool
    ) async {
        let subscription = services.engine.suggestions(for: request)
        let settles = keystroke.map { $0 + .milliseconds(ShownSuggestion.settleMilliseconds) }
        var logged = false
        var unsettled: [String]?
        for await update in subscription.updates {
            guard !Task.isCancelled else { return }
            if !logged, !update.candidates.isEmpty {
                logged = true
                let sinceKey = keystroke.map { Self.ms(ContinuousClock.now - $0) } ?? -1
                Self.log.info("Suggestion ms: \(sinceKey, privacy: .public) after the keystroke, prompt \(Self.ms(preparation), privacy: .public), engine \(Int(update.milliseconds), privacy: .public), \(update.reused ? "reused" : "new", privacy: .public) search, \(update.isFinal ? "final" : "growing", privacy: .public)")
            }
            let texts = update.candidates.map(\.text)
            let replaces = update.isFinal && !snapshot.isMidLine
            let settled = replaces && settles.map { ContinuousClock.now >= $0 } ?? replaces
            if replaces, !settled { unsettled = texts }
            present(texts, from: snapshot, kind: .completion, settled: settled)
        }
        if !logged, !Task.isCancelled {
            Self.log.info("Suggestion: none for this text (\(snapshot.isMidLine ? "mid-line" : "line end", privacy: .public))")
            if forced { NSSound.beep() }
        }
        guard let unsettled, let settles else { return }
        do {
            try await Task.sleep(until: settles, clock: .continuous)
        } catch {
            return
        }
        guard lastTyping == keystroke else { return }
        present(unsettled, from: snapshot, kind: .completion, settled: true)
    }

    private func buildPrompt(
        for snapshot: FieldSnapshot, context: SessionContext, mode: CompletionRequest.Mode, builder: PromptBuilder
    ) async -> BuiltPrompt {
        let rule = rule(for: snapshot)
        let prompt = await Self.build(PromptContext(
            instructions: instructions(for: rule),
            userName: preferences.userName.isEmpty ? nil : preferences.userName,
            appName: snapshot.app.name,
            windowTitle: context.windowTitle ?? snapshot.windowTitle,
            domain: snapshot.url?.host(),
            fieldKind: snapshot.kind,
            fieldLabel: snapshot.label,
            examples: context.examples,
            clipboard: context.clipboard,
            screenText: context.screenText,
            textBefore: snapshot.textBefore,
            textAfter: snapshot.isMidLine ? snapshot.textAfter : "",
            mode: mode == .draft ? .draft : .inline,
            keepsDate: context.keepsDate
        ), with: builder)
        if prompt.includesDate, !context.keepsDate, field?.id == snapshot.id {
            self.context?.keepsDate = true
        }
        return prompt
    }

    @concurrent
    nonisolated private static func build(_ context: PromptContext, with builder: PromptBuilder) async -> BuiltPrompt {
        builder.build(context)
    }

    private func prewarm(_ snapshot: FieldSnapshot, context: SessionContext) {
        guard field?.id == snapshot.id else { return }
        Task { await stage(context) }
    }

    private func mayComplete(_ snapshot: FieldSnapshot, forced: Bool) -> Bool {
        guard case .ready = appState.modelStatus, snapshot.selectedText.isEmpty else { return false }
        guard !appState.isPaused(bundleID: snapshot.app.bundleID) else { return false }
        let rule = rule(for: snapshot)
        guard rule.completionsEnabled != false else { return false }
        if forced { return true }
        guard preferences.completionsEnabled else { return false }
        if isBrieflyPaused { return false }
        if InputSource.isInputMethodActive { return false }
        if power.isOnBattery, preferences.batteryOnDemandOnly { return false }
        if snapshot.isSingleWord { return false }
        if snapshot.isMidLine, !(rule.midLineEnabled ?? preferences.midLineEnabled) { return false }
        let currentLine = snapshot.textBefore.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return currentLine.contains(where: \.isLetter)
    }

    private var isBrieflyPaused: Bool {
        guard let pausedUntil else { return false }
        return ContinuousClock.now < pausedUntil
    }

    private var maxWords: Int {
        var length = preferences.completionLength
        if power.isOnBattery, preferences.batteryShorterCompletions, length.rawValue > CompletionLength.medium.rawValue {
            length = .medium
        }
        return length.maxWords
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    private static func restOfLine(_ text: String) -> String {
        String(text.prefix { !$0.isNewline })
    }

    private func instructions(for rule: AppRule) -> String? {
        let parts = [preferences.customInstructions, rule.customInstructions ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Context

    private func loadContext(for snapshot: FieldSnapshot) {
        let rule = rule(for: snapshot)
        let request = ContextRequest(
            snapshot: snapshot,
            exampleLimit: Self.exampleLimits[preferences.personalizationStrength],
            includeScreen: preferences.screenContextEnabled && rule.screenContextEnabled != false,
            allowOCR: preferences.ocrEnabled && appState.screenRecordingGranted,
            clipboard: preferences.clipboardContextEnabled ? ClipboardReader.recentText(maxAge: 120, maxCharacters: 1500) : nil,
            sessionKey: recorder.key
        )
        charactersSinceExamples = 0
        let task = Task { [memory = services.memory, screen] in
            await request.load(memory: memory, screen: screen)
        }
        contextTask = task
        Task { [weak self] in
            let loaded = await task.value
            guard let self, self.contextTask == task else { return }
            self.context = loaded
            Self.log.info("Context loaded: screen \(loaded.screenText?.count ?? 0, privacy: .public) chars, \(loaded.examples.count, privacy: .public) examples")
            if let current = self.field {
                self.prewarm(current, context: loaded)
            }
            await self.swapInOCRText(from: request, session: task)
        }
    }

    private func swapInOCRText(from request: ContextRequest, session: Task<SessionContext, Never>) async {
        guard let text = await request.screenTextAfterOCR(screen: screen) else { return }
        let previous = context?.screenText?.count ?? 0
        guard contextTask == session, var next = context, text.count > previous else { return }
        next.screenText = text
        await stage(next)
        guard contextTask == session, context != nil else { return }
        context?.screenText = text
        Self.log.info("Swapped in screen text from OCR: \(previous, privacy: .public) -> \(text.count, privacy: .public) chars")
    }

    /// Decodes the prompt `next` gives the focused field beside the one in use, a few dozen tokens at a time
    /// while no suggestion request needs the engine; returns once that is done, replaced by a newer one, or
    /// skipped. Callers keep the current context, whose prompt the engine serves meanwhile, until this returns,
    /// so no keystroke waits for the new context's decode (about a second for a screenful of text).
    private func stage(_ next: SessionContext) async {
        guard let current = field, let builder = models.builder, mayComplete(current, forced: true),
              preferences.completionsEnabled, !isBrieflyPaused,
              !(power.isOnBattery && preferences.batteryOnDemandOnly) else { return }
        let prompt = await buildPrompt(for: current, context: next, mode: .inline, builder: builder)
        let started = ContinuousClock.now
        let staged = await services.engine.stage(prompt: prompt.text)
        Self.log.info("Staged a new context in \(Self.ms(ContinuousClock.now - started), privacy: .public) ms\(staged ? "" : ", replaced", privacy: .public)")
    }

    private func currentContext() async -> SessionContext {
        if let context { return context }
        guard let contextTask else { return SessionContext() }
        return await contextTask.value
    }

    private func refreshExamplesIfNeeded(for snapshot: FieldSnapshot) {
        guard context != nil, charactersSinceExamples > Self.examplesRefreshCharacters else { return }
        charactersSinceExamples = 0
        let limit = Self.exampleLimits[preferences.personalizationStrength]
        Task { [weak self, memory = services.memory, key = recorder.key] in
            let examples = await ContextRequest.examples(for: snapshot, limit: limit, excluding: key, memory: memory)
            guard let self, self.field?.id == snapshot.id, var next = self.context, next.examples != examples else { return }
            next.examples = examples
            await self.stage(next)
            guard self.field?.id == snapshot.id, self.context != nil else { return }
            self.context?.examples = examples
            Self.log.info("Swapped in \(examples.count, privacy: .public) refreshed examples")
        }
    }

    private func bias(for language: String?) async -> TokenBias? {
        let strength = Self.biasStrengths[preferences.personalizationStrength]
        guard strength > 0, let memory = services.memory else { return nil }
        if let followers, followers.language == language {
            return followers.value.isEmpty ? nil : TokenBias(followers: followers.value, strength: strength)
        }
        let loaded = await Task.detached {
            do {
                return try memory.followers(language: language, limit: 8)
            } catch {
                Self.log.error("Loading word preferences failed: \(error.localizedDescription, privacy: .public)")
                return [:]
            }
        }.value
        followers = (language, loaded)
        return loaded.isEmpty ? nil : TokenBias(followers: loaded, strength: strength)
    }

    // MARK: Showing suggestions

    private func present(_ texts: [String], from snapshot: FieldSnapshot, kind: ActiveSuggestion.Kind, settled: Bool) {
        let candidates = texts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let current = field, current.id == snapshot.id, !candidates.isEmpty, emoji == nil, !editedSinceRead,
              Self.restOfLine(current.textAfter) == Self.restOfLine(snapshot.textAfter) else { return }
        if case .typos = suggestion?.kind { return }
        let textBefore = current.textBefore + typedSinceRead
        let fresh = ActiveSuggestion(fieldID: snapshot.id, anchor: snapshot.textBefore, candidates: candidates, kind: kind)
        guard var next = fresh.advanced(to: textBefore) else { return }
        if kind == .completion, let shown = suggestion, shown.kind == .completion, let aligned = shown.advanced(to: textBefore) {
            next = aligned.merged(with: next, settled: settled)
        }
        guard next != suggestion else { return }
        // Until the field reports the typed text the caret position is stale; the read that follows shows it.
        // Meanwhile the text on screen stays, so an accept inserts only what the user saw.
        if !typedSinceRead.isEmpty, let shown = suggestion?.advanced(to: textBefore), shown.isDrawn, shown.text != next.text {
            deferred = next
            return
        }
        if !typedSinceRead.isEmpty || (suggestion?.text == next.text && suggestion?.anchor == next.anchor) {
            suggestion = next
            return
        }
        show(next, in: current)
    }

    private func showDraftProgress(_ partial: String, from snapshot: FieldSnapshot, generation: Int) {
        guard inFlight?.id == generation, let current = field, current.id == snapshot.id,
              current.textBefore == snapshot.textBefore, !partial.isEmpty else { return }
        show(ActiveSuggestion(fieldID: snapshot.id, anchor: snapshot.textBefore, candidates: [partial], kind: .draft), in: current)
    }

    private func show(_ next: ActiveSuggestion, in snapshot: FieldSnapshot) {
        acceptWatchdog?.cancel()
        acceptWatchdog = nil
        var appearance = overlay.appearance
        appearance.opacity = preferences.overlayOpacity
        overlay.appearance = appearance
        let wraps = next.kind == .draft || (!snapshot.isMidLine && snapshot.fieldFrame.height > snapshot.caretRect.height * 2.5)
        let shown = if case .typos(let fixes) = next.kind {
            showTypos(fixes, in: snapshot)
        } else {
            overlay.show(next.text, for: snapshot, multiline: wraps)
        }
        guard shown else {
            hideSuggestion()
            return
        }
        if next.kind == .completion, suggestion?.isDrawn != true {
            suggestionUsed = false
            recordSuggestion(.shown, bundleID: snapshot.app.bundleID)
        }
        suggestion = next
        suggestion?.isDrawn = true
        deferred = nil
        bindSuggestionKeys(for: snapshot)
    }

    private func hideSuggestion() {
        acceptWatchdog?.cancel()
        acceptWatchdog = nil
        if case .typos = suggestion?.kind { overlay.hideStatus() }
        suggestion = nil
        deferred = nil
        overlay.hide()
        bindKeys([])
    }

    private func hidePicker() {
        guard emoji != nil else { return }
        emoji = nil
        overlay.hidePicker()
        bindKeys([])
    }

    private func hideAll() {
        hideSuggestion()
        hidePicker()
    }

    // MARK: Accept keys

    private func bindSuggestionKeys(for snapshot: FieldSnapshot) {
        let bindings: [(HotKey, @MainActor @Sendable () -> Void)] = [
            (preferences.acceptFullKey, { [weak self] in self?.acceptAll() }),
            (preferences.acceptWordKey, { [weak self] in self?.acceptWord() }),
            (.optionTab, { [weak self] in self?.passTab() }),
            (.escape, { [weak self] in self?.dismissOrIgnoreTypos() }),
        ]
        bindKeys(bindings, for: snapshot)
    }

    private func bindKeys(_ bindings: [(HotKey, @MainActor @Sendable () -> Void)], for snapshot: FieldSnapshot) {
        let tabAllowed = rule(for: snapshot).tabAcceptEnabled != false
        let escapeAllowed = preferences.escapeBehavior != .passToApp
        bindKeys(bindings.filter { key, _ in
            if key == .tab || key == .optionTab { return tabAllowed }
            if key == .escape { return escapeAllowed }
            return true
        })
    }

    private func bindKeys(_ bindings: [(HotKey, @MainActor @Sendable () -> Void)]) {
        var bindings = bindings
        if autoFixUndo != nil {
            bindings.append((.deleteBackward, { [weak self] in self?.undoAutoFix() }))
        }
        let wanted = Set(bindings.map(\.0))
        for key in registeredKeys.subtracting(wanted) {
            hotKeys.unregister(key)
        }
        for (key, action) in bindings where !hotKeys.register(key, action: action) {
            Self.log.error("Registering hot key \(key.keyCode) failed")
        }
        registeredKeys = wanted
    }

    private func acceptWord() {
        guard let current = suggestion, let snapshot = field else { return }
        if case .typos = current.kind {
            acceptTypos()
            return
        }
        let chunk = WordSplitter.nextChunk(
            of: current.text,
            includeTrailingSpace: preferences.includeTrailingSpace,
            includeTrailingPunctuation: preferences.includeTrailingPunctuation
        )
        guard !chunk.isEmpty else { return }
        noteUsed(current, in: snapshot)
        typedSinceRead += chunk
        suggestion = current.advanced(to: current.anchor + chunk)
        suggestion?.isPartlyAccepted = true
        // The ghost stays up: the inserted word lands on its own ghost letters, and the field read that
        // follows redraws the rest at the new caret.
        if suggestion == nil {
            overlay.hide()
            bindKeys([])
        }
        insert(chunk, into: snapshot, kind: .word)
        accepted(into: snapshot)
        watchForInsertEcho()
    }

    /// An accept counts as typing, so a suggestion follows it however long the user read first. The engine
    /// starts on the text the accept produces before the field reports it, and the field is read once the
    /// insertion is posted, for apps that report it late or not at all.
    private func accepted(into snapshot: FieldSnapshot) {
        lastTyping = .now
        scheduleRefresh(after: .milliseconds(40), afterInsertion: true)
        guard suggestion == nil || !power.prefersEconomy else { return }
        var predicted = snapshot
        predicted.textBefore += typedSinceRead
        requestCompletion(for: predicted)
    }

    /// The rest of the suggestion shows again when the field reports the inserted word. If a last read
    /// still does not show it (field limit, dropped events), the suggestion must not keep the accept keys.
    private func watchForInsertEcho() {
        guard suggestion != nil else { return }
        acceptWatchdog?.cancel()
        let pending = insertion
        acceptWatchdog = Task { [weak self, tracker] in
            await pending?.value
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            // Showing the advanced suggestion cancels this task.
            if let snapshot = await tracker.snapshot(), !Task.isCancelled { self?.handle(.changed(snapshot)) }
            guard !Task.isCancelled else { return }
            self?.hideSuggestion()
        }
    }

    private func acceptAll() {
        guard let current = suggestion, let snapshot = field else { return }
        if case .typos = current.kind {
            acceptTypos()
            return
        }
        noteUsed(current, in: snapshot)
        typedSinceRead += current.text
        hideSuggestion()
        insert(current.text, into: snapshot, kind: current.kind == .draft ? .draft : .full)
        accepted(into: snapshot)
    }

    private func dismiss() {
        hideAll()
        cancelGeneration()
        switch preferences.escapeBehavior {
        case .pauseBriefly:
            pausedUntil = .now + Self.briefPause
        case .offUntilAppSwitch:
            if let bundleID = field?.app.bundleID {
                appState.pause(bundleID: bundleID, .untilAppSwitch)
            }
        case .passToApp:
            break
        }
    }

    private func passTab() {
        guard let pid = field?.app.pid else { return }
        hideSuggestion()
        TextInserter.postTab(to: pid)
    }

    private func insert(_ text: String, into snapshot: FieldSnapshot, kind: AcceptanceEvent.Kind) {
        let mode: InsertionMode = text.contains(where: \.isNewline) ? .paste : rule(for: snapshot).insertionMode ?? .standard
        let pid = snapshot.app.pid
        enqueueInsertion { await TextInserter.insert(text, into: pid, mode: mode) }
        recordAcceptance(of: text, kind: kind, bundleID: snapshot.app.bundleID)
    }

    private func enqueueInsertion(_ work: @escaping @MainActor () async -> Void) {
        let previous = insertion
        insertion = Task {
            await previous?.value
            await work()
        }
    }

    private func noteUsed(_ current: ActiveSuggestion, in snapshot: FieldSnapshot) {
        guard current.kind == .completion, !suggestionUsed else { return }
        suggestionUsed = true
        recordSuggestion(.used, bundleID: snapshot.app.bundleID)
    }

    private func countsTowardStatistics(_ bundleID: String) -> Bool {
        bundleID != Bundle.main.bundleIdentifier
    }

    private func recordSuggestion(_ outcome: SuggestionOutcome, bundleID: String) {
        guard countsTowardStatistics(bundleID), let memory = services.memory else { return }
        Task.detached {
            do {
                try memory.recordSuggestion(outcome, bundleID: bundleID)
            } catch {
                Self.log.error("Recording a suggestion count failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func recordAcceptance(of text: String, kind: AcceptanceEvent.Kind, bundleID: String) {
        guard countsTowardStatistics(bundleID) else {
            appState.practiceAcceptances.insert(kind)
            return
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        appState.wordsToday += words
        guard let memory = services.memory else { return }
        let event = AcceptanceEvent(kind: kind, bundleID: bundleID, words: words, characters: text.count)
        Task.detached {
            do {
                try memory.recordAcceptance(event)
            } catch {
                Self.log.error("Recording an acceptance failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Typos

    private func checkTyposIfNeeded(for snapshot: FieldSnapshot) -> Bool {
        let rule = rule(for: snapshot)
        guard rule.typoFixesEnabled != false, (rule.typoFixesEnabled ?? preferences.typoFixesEnabled) || preferences.suppressOnTypo,
              snapshot.selectedText.isEmpty, snapshot.kind != .code, snapshot.kind != .terminal,
              !InputSource.isInputMethodActive else { return false }
        let language = LanguageDetector.dominantLanguage(of: String(snapshot.textBefore.suffix(400)))
        let found = preferences.sentenceTypoCheck && SpellCheck.endsSentence(snapshot.textBefore)
            ? SpellCheck.sentence(endingAt: snapshot.textBefore, language: language)
            : SpellCheck.lastWord(in: snapshot.textBefore, language: language).map { [$0] } ?? []
        let ignored = Set(preferences.ignoredTypoWords)
        let candidates = found.filter { !ignored.contains($0.word.lowercased()) }.suffix(Self.maxSentenceTypos)
        guard !candidates.isEmpty else { return false }
        typoCheck?.cancel()
        typoCheck = Task { [weak self] in await self?.judge(Array(candidates), in: snapshot) }
        return true
    }

    private func judge(_ found: [Misspelling], in snapshot: FieldSnapshot) async {
        var fixes: [TypoFix] = []
        var automatic = true
        for (index, misspelling) in found.enumerated() {
            guard !Task.isCancelled else { return }
            if await isKnownWord(misspelling.word) { continue }
            let context = misspelling.scoringContext(
                in: snapshot.textBefore, next: found.indices.contains(index + 1) ? found[index + 1] : nil, earlierFixes: fixes
            )
            let judgment = await typoJudge.judge(
                misspelling, score: await typoScorer(for: snapshot, before: context.before, after: context.after)
            )
            guard let correction = judgment.verdict.correction else { continue }
            if case .offer = judgment.verdict { automatic = false }
            fixes.append(TypoFix(word: misspelling.word, correction: correction, distanceFromEnd: misspelling.distanceFromEnd))
        }
        guard !Task.isCancelled, let current = field, current.id == snapshot.id, current.textBefore == snapshot.textBefore,
              typedSinceRead.isEmpty, suggestion == nil else { return }
        let offers = rule(for: snapshot).typoFixesEnabled ?? preferences.typoFixesEnabled
        guard offers, !fixes.isEmpty else {
            if fixes.isEmpty || !preferences.suppressOnTypo { requestCompletion(for: snapshot) }
            return
        }
        if preferences.autoFixTypos, automatic, fixes.count == 1, let fix = fixes.first, fix.endsText(snapshot.textBefore),
           Self.autoFixLanguages.contains(LanguageDetector.dominantLanguage(of: String(snapshot.textBefore.suffix(400))) ?? "") {
            autoFix(fix, in: snapshot)
            return
        }
        let candidates = [fixes.map(\.correction).joined(separator: " ")]
        show(ActiveSuggestion(fieldID: snapshot.id, anchor: snapshot.textBefore, candidates: candidates, kind: .typos(fixes)), in: snapshot)
    }

    private func isKnownWord(_ word: String) async -> Bool {
        guard let memory = services.memory else { return false }
        let threshold = Self.knownWordSessions
        return await Task.detached {
            do {
                return try memory.sessionCount(containing: word) >= threshold
            } catch {
                Self.log.error("Looking up a word in the writing history failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }.value
    }

    private func typoScorer(
        for snapshot: FieldSnapshot, before textBefore: String, after suffix: String
    ) async -> (@Sendable (String) async throws -> Double)? {
        guard case .ready = appState.modelStatus, let builder = models.builder else { return nil }
        var before = snapshot
        before.textBefore = textBefore
        before.textAfter = ""
        let prompt = await buildPrompt(for: before, context: await currentContext(), mode: .inline, builder: builder)
        let engine = services.engine
        let (text, partial) = (prompt.text, prompt.partialWord)
        return { candidate in
            let scored = try await engine.score(prompt: text, continuation: partial + candidate + suffix)
            guard scored.characters > 0 else { throw UnscoredContinuation() }
            return scored.logprob
        }
    }

    private struct UnscoredContinuation: Error {}

    private func showTypos(_ fixes: [TypoFix], in snapshot: FieldSnapshot) -> Bool {
        if fixes.count == 1, let fix = fixes.first, fix.endsText(snapshot.textBefore) {
            overlay.hideStatus()
            return overlay.showTypoFix(
                word: fix.word, closing: String(snapshot.textBefore.suffix(fix.distanceFromEnd)), correction: fix.correction,
                for: snapshot
            )
        }
        let shown = 3
        var text = fixes.prefix(shown).map { "\($0.word) → \($0.correction)" }.joined(separator: ", ")
        if fixes.count > shown { text += " +\(fixes.count - shown)" }
        let key = rule(for: snapshot).tabAcceptEnabled != false ? preferences.acceptWordKey : preferences.acceptFullKey
        notice?.cancel()
        notice = nil
        overlay.hide()
        return overlay.showStatus(text, detail: "\(key == .tab ? "⇥" : key.displayName) fixes", near: snapshot.caretRect)
    }

    private func acceptTypos() {
        guard let current = suggestion, case .typos(let fixes) = current.kind, let snapshot = field else { return }
        hideSuggestion()
        guard let edit = edit(applying: fixes, in: snapshot) else { return }
        recordAcceptance(of: fixes.map(\.correction).joined(separator: " "), kind: .typo, bundleID: snapshot.app.bundleID)
        continueAfter(edit, in: snapshot)
    }

    private func edit(applying fixes: [TypoFix], in snapshot: FieldSnapshot) -> Proofread? {
        guard let tail = TypoFix.tail(of: snapshot.textBefore, applying: fixes) else {
            Self.log.info("Typo fix skipped: the text moved")
            return nil
        }
        let edit = Proofread(original: tail.original, corrected: tail.corrected)
        apply(edit, in: snapshot)
        return edit
    }

    /// Counts as typing, so the read that shows the corrected text asks for a suggestion.
    private func continueAfter(_ edit: Proofread, in snapshot: FieldSnapshot) {
        lastTyping = .now
        scheduleRefresh(after: .milliseconds(40), afterInsertion: true)
    }

    private func dismissOrIgnoreTypos() {
        guard case .typos(let fixes) = suggestion?.kind else {
            dismiss()
            return
        }
        fixes.forEach { preferences.ignoreTypo($0.word) }
        hideSuggestion()
    }

    private func autoFix(_ fix: TypoFix, in snapshot: FieldSnapshot) {
        guard let edit = edit(applying: [fix], in: snapshot) else { return }
        recordAcceptance(of: fix.correction, kind: .typo, bundleID: snapshot.app.bundleID)
        clearAutoFixUndo()
        let expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.autoFixUndoWindow)
            } catch {
                return
            }
            self?.clearAutoFixUndo()
        }
        autoFixUndo = (snapshot.id, edit, fix.word, expiry)
        bindKeys([])
        showNotice("\(fix.word) → \(fix.correction)", detail: "⌫ undo", in: snapshot, for: Self.autoFixUndoWindow)
        continueAfter(edit, in: snapshot)
    }

    private func undoAutoFix() {
        guard let undo = autoFixUndo, let snapshot = field, snapshot.id == undo.field else { return }
        clearAutoFixUndo()
        hideAll()
        cancelGeneration()
        apply(undo.edit.reverted, in: snapshot)
        preferences.ignoreTypo(undo.word)
        showNotice("Kept \u{201C}\(undo.word)\u{201D}", in: snapshot)
    }

    private func clearAutoFixUndo() {
        guard let undo = autoFixUndo else { return }
        undo.expiry.cancel()
        autoFixUndo = nil
        guard registeredKeys.contains(.deleteBackward) else { return }
        hotKeys.unregister(.deleteBackward)
        registeredKeys.remove(.deleteBackward)
    }

    private func prewarmProofreading() {
        guard preferences.proofreadEnabled, appState.foundationModelsUnavailableReason == nil,
              lastProofreadPrewarm.map({ ContinuousClock.now - $0 > Self.proofreadPrewarmInterval }) ?? true else { return }
        lastProofreadPrewarm = .now
        services.assistant.prewarm()
    }

    // MARK: Emoji

    private func showEmojiPickerIfNeeded(for snapshot: FieldSnapshot) -> Bool {
        guard preferences.emojiEnabled, let query = EmojiIndex.pendingQuery(in: snapshot.textBefore) else {
            hidePicker()
            return false
        }
        let results = EmojiIndex.shared.search(query)
        guard !results.isEmpty else {
            hidePicker()
            return false
        }
        emoji = (query, results.map(\.emoji))
        overlay.showPicker(results.map { PickerItem(title: $0.emoji, detail: $0.name) }, near: snapshot.caretRect) { [weak self] index in
            self?.pickEmoji(index)
        }
        var bindings: [(HotKey, @MainActor @Sendable () -> Void)] = []
        for index in results.indices {
            guard let key = HotKey.digit(index + 1) else { continue }
            bindings.append((key, { [weak self] in self?.pickEmoji(index) }))
        }
        bindings.append((preferences.acceptWordKey, { [weak self] in self?.pickEmoji(0) }))
        bindings.append((preferences.acceptFullKey, { [weak self] in self?.pickEmoji(0) }))
        bindings.append((.escape, { [weak self] in self?.hidePicker() }))
        bindKeys(bindings, for: snapshot)
        return true
    }

    private func pickEmoji(_ index: Int) {
        guard let emoji, emoji.choices.indices.contains(index), let snapshot = field else { return }
        let choice = emoji.choices[index]
        let length = emoji.query.count + 1
        hidePicker()
        let pid = snapshot.app.pid
        let mode = rule(for: snapshot).insertionMode ?? .standard
        enqueueInsertion {
            await TextInserter.deleteBackward(count: length, in: pid)
            await TextInserter.insert(choice, into: pid, mode: mode)
        }
        recordAcceptance(of: choice, kind: .emoji, bundleID: snapshot.app.bundleID)
    }

    // MARK: Snippets

    private func expandSnippetIfNeeded() {
        let bundleID = field?.app.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !appState.isPaused(bundleID: bundleID) else { return }
        let engine = SnippetEngine(snippets: services.snippets.enabledSnippets)
        guard let match = engine.match(typedTail: typedTail) else { return }
        typedTail = ""
        Task { [weak self] in await self?.expand(match, engine: engine) }
    }

    private func expand(_ match: SnippetMatch, engine: SnippetEngine) async {
        do {
            try await Task.sleep(for: .milliseconds(40))
        } catch {
            return
        }
        guard let snapshot = await tracker.snapshot(), snapshot.textBefore.hasSuffix(match.snippet.trigger) else { return }
        hideAll()
        cancelGeneration()
        let assistant = services.assistant
        let surrounding = String(snapshot.textBefore.suffix(800))
        let expansion = await engine.expand(
            match.snippet,
            clipboard: SnippetEngine.usesClipboard(match.snippet) ? NSPasteboard.general.string(forType: .string) : nil,
            now: .now,
            ai: { instruction in
                do {
                    return try await assistant.fill(instruction: instruction, context: surrounding)
                } catch {
                    Self.log.error("Snippet AI fill failed: \(error.localizedDescription)")
                    return ""
                }
            }
        )
        guard let latest = await tracker.snapshot(), latest.id == snapshot.id, latest.textBefore == snapshot.textBefore else {
            Self.log.info("Snippet skipped: the field changed while expanding")
            return
        }
        let pid = snapshot.app.pid
        let mode: InsertionMode = expansion.text.contains(where: \.isNewline) ? .paste : rule(for: snapshot).insertionMode ?? .standard
        enqueueInsertion {
            await TextInserter.deleteBackward(count: match.triggerLength, in: pid)
            await TextInserter.insert(expansion.text, into: pid, mode: mode)
            await TextInserter.moveCaretLeft(count: expansion.cursorOffsetFromEnd, in: pid)
        }
        recordAcceptance(of: expansion.text, kind: .snippet, bundleID: snapshot.app.bundleID)
    }

    // MARK: Shortcuts

    private func forceComplete() {
        Task { [weak self, tracker] in
            guard let snapshot = await tracker.snapshot() else { return }
            self?.startOnDemand(for: snapshot, mode: .inline)
        }
    }

    private func requestDraft() {
        guard preferences.draftEnabled else { return }
        Task { [weak self, tracker] in
            guard let snapshot = await tracker.snapshot() else { return }
            self?.startOnDemand(for: snapshot, mode: .draft)
        }
    }

    private func startOnDemand(for snapshot: FieldSnapshot, mode: CompletionRequest.Mode) {
        if field?.id != snapshot.id { focusMoved(to: snapshot) }
        field = snapshot
        typedSinceRead = ""
        editedSinceRead = false
        hideAll()
        // A multi-sentence draft in the middle of a line breaks the text after the caret (eval: half of mid-line rows).
        let mode: CompletionRequest.Mode = snapshot.isMidLine ? .inline : mode
        requestCompletion(for: snapshot, mode: mode, forced: true)
    }

    private func presentSelectionActions() {
        guard preferences.selectionActionsEnabled else { return }
        Task { [weak self, tracker] in
            guard let self else { return }
            guard let snapshot = await tracker.snapshot(), !snapshot.selectedText.isEmpty else {
                NSSound.beep()
                return
            }
            self.showSelectionActions(for: snapshot, near: snapshot.caretRect, takesFocus: true)
        }
    }

    private func showSelectionActions(for snapshot: FieldSnapshot, near rect: CGRect, takesFocus: Bool) {
        hideAll()
        cancelGeneration()
        let surrounding = String(snapshot.textBefore.suffix(400)) + snapshot.selectedText + String(snapshot.textAfter.prefix(400))
        selectionActions.present(
            selectedText: snapshot.selectedText, near: rect, surroundingText: surrounding, takesFocus: takesFocus
        ) { [weak self] replacement in
            self?.replaceSelection(in: snapshot, with: replacement)
        }
    }

    private func selectionMoved(in snapshot: FieldSnapshot) {
        autoSelectionTask?.cancel()
        let selected = snapshot.selectedText
        if selectionActions.isPassive, selectionActions.presentedText != selected {
            selectionActions.dismiss()
        }
        if selected.isEmpty { autoShownSelection = nil }
        guard preferences.showsSelectionActionsOnSelect, preferences.selectionActionsEnabled,
              appState.foundationModelsUnavailableReason == nil,
              !selected.allSatisfy(\.isWhitespace), selected != autoShownSelection
        else { return }
        autoSelectionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.autoSelectionDelay)
                while NSEvent.pressedMouseButtons != 0 {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                return
            }
            guard let self, let field = self.field, field.id == snapshot.id, field.selectedText == selected,
                  !self.selectionActions.isPresented
            else { return }
            self.autoShownSelection = selected
            self.showSelectionActions(for: field, near: self.pointerMovedLast ? .zero : field.caretRect, takesFocus: false)
        }
    }

    private func replaceSelection(in snapshot: FieldSnapshot, with text: String) {
        let pid = snapshot.app.pid
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        let mode: InsertionMode = text.contains(where: \.isNewline) || text.count > 200 ? .paste : rule(for: snapshot).insertionMode ?? .standard
        enqueueInsertion {
            do {
                try await Task.sleep(for: .milliseconds(60))
            } catch {
                return
            }
            await TextInserter.insert(text, into: pid, mode: mode)
        }
        recordAcceptance(of: text, kind: .action, bundleID: snapshot.app.bundleID)
    }

    // MARK: Proofreading

    private func proofread() {
        guard preferences.proofreadEnabled, proofreading == nil else { return }
        proofreading = Task { [weak self, tracker] in
            defer { self?.proofreading = nil }
            guard let snapshot = await tracker.snapshot() else {
                NSSound.beep()
                return
            }
            await self?.proofread(snapshot)
        }
    }

    private func proofread(_ snapshot: FieldSnapshot) async {
        let undo = lastProofread.flatMap { last in
            last.field == snapshot.id && snapshot.selectedText.isEmpty && snapshot.textBefore.hasSuffix(last.result.corrected)
                ? last.result.reverted : nil
        }
        lastProofread = nil
        if field?.id != snapshot.id { focusMoved(to: snapshot) }
        field = snapshot
        lastTyping = nil
        hideAll()
        cancelGeneration()
        if let undo {
            guard await keysReleased(in: snapshot) else { return }
            apply(undo, in: snapshot)
            showNotice("↩ Restored", in: snapshot)
            return
        }
        let replacesSelection = !snapshot.selectedText.isEmpty
        let text = replacesSelection ? snapshot.selectedText : Self.paragraph(before: snapshot.textBefore)
        guard text.contains(where: \.isLetter) else {
            NSSound.beep()
            return
        }
        guard text.count <= Self.proofreadLimit else {
            showNotice("Too long to proofread. Select a shorter part.", in: snapshot)
            return
        }
        showNotice("Proofreading…", busy: true, in: snapshot, for: nil)
        var output = text
        do {
            for try await partial in services.assistant.run(.fixGrammar, on: text) {
                output = partial
            }
        } catch is CancellationError {
            hideNotice()
            return
        } catch {
            Self.log.error("Proofreading failed: \(error.localizedDescription, privacy: .public)")
            showNotice(error.localizedDescription, in: snapshot)
            return
        }
        guard !Task.isCancelled, let latest = await tracker.snapshot(), latest.id == snapshot.id,
              latest.textBefore == snapshot.textBefore, latest.selectedText == snapshot.selectedText else {
            Self.log.info("Proofread skipped: the field changed")
            hideNotice()
            return
        }
        let result = Proofread(original: text, modelOutput: output)
        guard !result.isUnchanged else {
            showNotice("✓ No errors", in: latest)
            return
        }
        guard !result.rewritesTooMuch else {
            Self.log.info("Proofread skipped: the model rewrote the text")
            showNotice("Not applied: the result rewrote your text", in: latest)
            return
        }
        guard await keysReleased(in: latest) else { return }
        if replacesSelection {
            let corrected = result.corrected
            let mode = insertionMode(for: corrected, in: latest)
            enqueueInsertion { await TextInserter.insert(corrected, into: latest.app.pid, mode: mode) }
        } else {
            apply(result, in: latest)
        }
        lastProofread = (latest.id, result)
        recordAcceptance(of: result.changes.map(\.new).joined(separator: " "), kind: .typo, bundleID: latest.app.bundleID)
        await insertion?.value
        let after = await tracker.snapshot() ?? latest
        let undoHint = KeyboardShortcuts.getShortcut(for: .proofread).map { "\($0) undo" }
        showNotice(Self.summary(of: result), detail: undoHint, in: after)
    }

    private func keysReleased(in snapshot: FieldSnapshot) async -> Bool {
        guard await TextInserter.waitForModifierRelease() else {
            Self.log.info("Proofread skipped: modifier keys stayed down")
            showNotice("Release the keys to proofread", in: snapshot)
            return false
        }
        return true
    }

    private func apply(_ proofread: Proofread, in snapshot: FieldSnapshot) {
        let pid = snapshot.app.pid
        let mode = insertionMode(for: proofread.insertion, in: snapshot)
        enqueueInsertion {
            await TextInserter.deleteBackward(count: proofread.deleteCount, in: pid)
            await TextInserter.insert(proofread.insertion, into: pid, mode: mode)
        }
    }

    private func insertionMode(for text: String, in snapshot: FieldSnapshot) -> InsertionMode {
        text.contains(where: \.isNewline) || text.count > 200 ? .paste : rule(for: snapshot).insertionMode ?? .standard
    }

    private static func summary(of result: Proofread) -> String {
        switch result.changes.count {
        case 0: "✓ Fixed spacing"
        case 1: "✓ 1 fix"
        case let count: "✓ \(count) fixes"
        }
    }

    private static func paragraph(before text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
    }

    private func showNotice(
        _ text: String, detail: String? = nil, busy: Bool = false, in snapshot: FieldSnapshot,
        for duration: Duration? = CompletionCoordinator.noticeDuration
    ) {
        notice?.cancel()
        guard overlay.showStatus(text, detail: detail, busy: busy, near: snapshot.caretRect) else {
            notice = nil
            return
        }
        notice = Task { [weak self] in
            guard let duration else { return }
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.hideNotice()
        }
    }

    private func hideNotice() {
        guard let notice else { return }
        notice.cancel()
        self.notice = nil
        overlay.hideStatus()
    }

    // MARK: Rules

    private func rule(for snapshot: FieldSnapshot) -> AppRule {
        let appRule = services.appRules.effectiveRule(for: snapshot.app.bundleID)
        guard let host = snapshot.url?.host() else { return appRule }
        return appRule.merged(with: rule(forKey: "domain:" + Self.normalizedHost(host)))
    }

    private func rule(forKey key: String) -> AppRule? {
        guard key.hasPrefix("domain:") else { return services.appRules.effectiveRule(for: key) }
        let host = String(key.dropFirst("domain:".count))
        let builtIn = BuiltInAppRules.domainRule(forHost: host)
        guard let user = services.appRules.rule(for: key) else { return builtIn }
        return (builtIn ?? AppRule(bundleID: key)).merged(with: user)
    }

    private static func normalizedHost(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    private func mayRecord(_ snapshot: FieldSnapshot) -> Bool {
        guard snapshot.app.bundleID != Bundle.main.bundleIdentifier, !appState.isPaused(bundleID: snapshot.app.bundleID),
              preferences.recordWriting, rule(for: snapshot).recordWriting != false else { return false }
        switch snapshot.kind {
        case .search, .terminal, .code, .form: return false
        case .email, .chat, .document, .aiPrompt, .unknown: return true
        }
    }
}

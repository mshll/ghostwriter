import ApplicationServices
import CoreGraphics
import Foundation
import GWCore

struct AppTarget: Sendable, Equatable {
    var identity: AppIdentity
    var bundleURL: URL?
}

enum ReadResult: Sendable {
    case field(FieldSnapshot)
    case ineligible(IneligibleReason)
    case timedOut

    var reason: IneligibleReason? {
        switch self {
        case .field: nil
        case .ineligible(let reason): reason
        case .timedOut: .unreadable
        }
    }
}

final class FieldContext {
    let element: AXElement
    let rule: AppRule
    let role: String
    let verdict: IneligibleReason?
    var label: String?
    var windowTitle: String?
    var url: URL?
    var language: String?
    var kind: FieldKind = .unknown
    var style: (caret: Int, value: FieldStyle)?
    var matchedFont: (size: Double, family: String?)?

    init(element: AXElement, rule: AppRule, role: String, verdict: IneligibleReason?) {
        self.element = element
        self.rule = rule
        self.role = role
        self.verdict = verdict
    }
}

struct FieldReader {
    static let beforeWindow = 3_300
    static let afterWindow = 1_000
    static let wholeValueLimit = 8_000
    static let selectionLimit = 20_000
    static let maxLength = 999_999
    static let maxCaretWidth: CGFloat = 100
    static let terminalTail = 12_000
    static let terminalFont = ".AppleSystemUIFontMonospaced-Regular"

    let app: AppTarget
    let rule: AppRule
    let calibration: CaretCalibration
    let readsTerminalAgentPrompts: Bool

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    private static let mailAddressFields: Set<String> = [
        "Mail.toField", "Mail.ccField", "Mail.bccField", "Mail.replyToField",
    ]
    private static let agentComposerClasses: Set<String> = [
        "aislash-editor-input", "ui-prompt-input-editor__input", "composer-editor",
    ]
    private static let agentPanelTokens = ["workbench.panel.chat", "windsurf.cascadePanel", "interactive-session"]
    private static let agentPanelDescriptions: Set<String> = ["Codex", "Claude Code"]

    // MARK: Context

    func context(for element: AXElement) throws(AXFailure) -> FieldContext {
        let attributes = try element.values([
            kAXRoleAttribute, kAXSubroleAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, AXName.userInputLabels, kAXTitleUIElementAttribute, AXName.domIdentifier,
            AXName.domClassList, kAXIdentifierAttribute, kAXWindowAttribute, AXName.language,
            kAXEditableAncestorAttribute, kAXParentAttribute, AXName.valueAutofillType,
        ])
        let role = AXDecode.string(attributes[kAXRoleAttribute]) ?? ""
        let subrole = AXDecode.string(attributes[kAXSubroleAttribute])
        let domIdentifier = AXDecode.string(attributes[AXName.domIdentifier])
        let domClasses = AXDecode.strings(attributes[AXName.domClassList])
        func rejected(_ reason: IneligibleReason) -> FieldContext {
            FieldContext(element: element, rule: rule, role: role, verdict: reason)
        }

        if role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole { return rejected(.secureField) }
        if ([domIdentifier].compactMap { $0 } + domClasses).contains(where: { $0.lowercased().contains("pass") }) {
            return rejected(.secureField)
        }
        let autofillType = AXDecode.string(attributes[AXName.valueAutofillType])
        if SecretFieldHints.isCredentialAutofill(autofillType) || SecretFieldHints.isPaymentAutofill(autofillType) {
            return rejected(.secureField)
        }
        let identifiers = [domIdentifier, AXDecode.string(attributes[kAXIdentifierAttribute])].compactMap { $0 } + domClasses
        if identifiers.contains(where: SecretFieldHints.namesPaymentOrOneTimeCode) { return rejected(.secureField) }
        let editsWholeDocument = try isEditableDocument(element, role: role)
        let isEditableWeb = attributes[kAXEditableAncestorAttribute] != nil || editsWholeDocument
        guard Self.textRoles.contains(role) || isEditableWeb else { return rejected(.notTextInput) }
        let label = try label(attributes)
        let labels = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { AXDecode.string(attributes[$0]) }
            + AXDecode.strings(attributes[AXName.userInputLabels]) + [label].compactMap { $0 }
        if labels.contains(where: { SecretFieldHints.mentionsPassword($0) || SecretFieldHints.namesPaymentOrOneTimeCode($0) }) {
            return rejected(.secureField)
        }
        if subrole == kAXSearchFieldSubrole { return rejected(.searchField) }

        let ancestry = try Ancestry(walkingUpFrom: AXDecode.element(attributes[kAXParentAttribute]))
        let webArea = role == AXName.webAreaRole ? element : ancestry.outermostWebArea
        let bundleID = app.identity.bundleID

        if AppCatalog.browsers.contains(bundleID), webArea == nil { return rejected(.addressBar) }
        let identifier = AXDecode.string(attributes[kAXIdentifierAttribute]) ?? ""
        if Self.mailAddressFields.contains(identifier) || ancestry.inSaveOrOpenPanel { return rejected(.excludedField) }

        let isTerminal = BuiltInAppRules.isTerminal(bundleID)
        if isTerminal, !readsTerminalAgentPrompts || !AppCatalog.agentPromptTerminals.contains(bundleID) {
            return rejected(.terminalShell)
        }

        var isAgentComposer = false
        var isCodeEditor = AppCatalog.isCodeEditor(bundleID)
        let isRuntimeTerminal = domClasses.contains("xterm-helper-textarea")
        if isRuntimeTerminal {
            guard readsTerminalAgentPrompts, bundleID == AppCatalog.orca else { return rejected(.terminalShell) }
            isCodeEditor = false
        } else if AppCatalog.vsCodeForks.contains(bundleID) {
            isAgentComposer = !Self.agentComposerClasses.isDisjoint(with: domClasses)
                || ancestry.domTokens.contains { token in Self.agentPanelTokens.contains { token.contains($0) } }
                || !Self.agentPanelDescriptions.isDisjoint(with: ancestry.descriptions)
            isCodeEditor = !isAgentComposer
        }
        if isCodeEditor, rule.codeEditorCompletions != true { return rejected(.codeEditor) }

        let context = FieldContext(element: element, rule: rule, role: role, verdict: nil)
        context.label = label
        context.language = AXDecode.nonEmptyString(attributes[AXName.language])
        let window = AXDecode.element(attributes[kAXWindowAttribute]) ?? ancestry.window
        if let window {
            let windowAttributes = try window.values([kAXTitleAttribute, kAXDocumentAttribute])
            context.windowTitle = AXDecode.nonEmptyString(windowAttributes[kAXTitleAttribute])
            context.url = AXDecode.url(windowAttributes[kAXDocumentAttribute])
        }
        if let webArea {
            let webAttributes = try webArea.values([kAXURLAttribute, AXName.language])
            context.url = AXDecode.url(webAttributes[kAXURLAttribute]) ?? context.url
            context.language = context.language ?? AXDecode.nonEmptyString(webAttributes[AXName.language])
        }
        let isBrowser = AppCatalog.browsers.contains(bundleID)
        let pageURLs = [context.url].compactMap { $0 } + ancestry.webAreaURLs
        if pageURLs.contains(where: { !PageScheme.isReadable($0, inBrowser: isBrowser) }) { return rejected(.excludedSite) }
        context.kind = FieldClassifier.kind(.init(
            bundleID: bundleID,
            role: role,
            label: context.label,
            domIdentifier: domIdentifier,
            url: webArea == nil ? nil : context.url,
            isWeb: webArea != nil,
            isTerminal: isTerminal || isRuntimeTerminal,
            isCodeEditor: isCodeEditor,
            isAgentComposer: isAgentComposer
        ))
        return context
    }

    /// A focused web area is the field when the whole document is editable, as in a Mail compose body. WebKit leaves
    /// `AXEditableAncestor` off the web area itself and marks it editable by making its value settable.
    private func isEditableDocument(_ element: AXElement, role: String) throws(AXFailure) -> Bool {
        role == AXName.webAreaRole ? try element.isSettable(kAXValueAttribute) : false
    }

    private func label(_ attributes: [String: CFTypeRef]) throws(AXFailure) -> String? {
        let direct = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .lazy.compactMap { AXDecode.nonEmptyString(attributes[$0]) }.first
        if let direct { return direct }
        if let inputLabel = AXDecode.strings(attributes[AXName.userInputLabels]).first(where: { !$0.isEmpty }) {
            return inputLabel
        }
        guard let titleElement = AXDecode.element(attributes[kAXTitleUIElementAttribute]) else { return nil }
        let titleAttributes = try titleElement.values([kAXValueAttribute, kAXTitleAttribute])
        return AXDecode.nonEmptyString(titleAttributes[kAXValueAttribute])
            ?? AXDecode.nonEmptyString(titleAttributes[kAXTitleAttribute])
    }

    // MARK: Read

    func read(_ context: FieldContext, diagnostics: inout ReadDiagnostics) throws(AXFailure) -> ReadResult {
        if context.kind == .terminal {
            return app.identity.bundleID == AppCatalog.orca
                ? try readOrcaPrompt(context)
                : try readTerminalPrompt(context, diagnostics: &diagnostics)
        }
        let element = context.element
        let attributes = try element.values([
            kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ])
        let frame = Self.frame(attributes)
        let count = AXDecode.int(attributes[kAXNumberOfCharactersAttribute])

        var text: ExtractedText?
        if let selection = AXDecode.range(attributes[kAXSelectedTextRangeAttribute]) {
            text = try TextExtractor.range(element, selection: selection, count: count)
        }
        if text == nil {
            text = try TextExtractor.markers(element)
        }
        guard let text else { return .ineligible(.unreadable) }
        diagnostics.textPath = text.path

        if let frame, Self.isTooSmall(frame, length: text.totalLength, kind: context.kind, bundleID: app.identity.bundleID) {
            return .ineligible(.tooSmall)
        }

        let direction = FieldClassifier.direction(before: text.before, after: text.after)
        var style = try style(context, text: text)
        let caret = try CaretLocator.caret(
            element, text: text, frame: frame, style: style, direction: direction,
            bundleID: app.identity.bundleID, calibration: calibration
        )
        diagnostics.caretSource = caret.source
        if style.fontName == nil, let size = style.fontSize {
            style.fontName = try matchedFont(context, text: text, size: size, style: style)
        }

        return .field(FieldSnapshot(
            id: FieldID(pid: app.identity.pid, elementHash: element.cfHash),
            app: app.identity,
            textBefore: text.before,
            textAfter: text.after,
            selectedText: text.selected,
            caretRect: caret.rect,
            fieldFrame: frame ?? .zero,
            style: style,
            kind: context.kind,
            direction: direction,
            label: context.label,
            windowTitle: context.windowTitle,
            url: context.url,
            language: context.language,
            caretIsEstimated: caret.source == .estimate
        ))
    }

    /// Reads the end of the terminal's text, where an agent draws its input box. The caret rect comes from the
    /// character the caret follows: a collapsed range has no bounds in a terminal.
    private func readTerminalPrompt(_ context: FieldContext, diagnostics: inout ReadDiagnostics) throws(AXFailure) -> ReadResult {
        let element = context.element
        let attributes = try element.values([
            kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ])
        guard let count = AXDecode.int(attributes[kAXNumberOfCharactersAttribute]), count > 0 else {
            return .ineligible(.terminalShell)
        }
        var start = max(0, count - Self.terminalTail)
        guard var screen = try TextExtractor.string(element, CFRange(location: start, length: count - start)) else {
            return .ineligible(.unreadable)
        }
        diagnostics.textPath = .stringForRange
        if start > 0 {
            let newline = screen.range(of: "\n")
            guard newline.location != NSNotFound else { return .ineligible(.terminalShell) }
            screen = screen.substring(from: newline.location + 1) as NSString
            start += newline.location + 1
        }
        let cursor = AXDecode.range(attributes[kAXSelectedTextRangeAttribute]).map { $0.location - start }
        guard let prompt = TerminalAgentPrompt.find(in: screen as String, cursor: cursor) else {
            return .ineligible(.terminalShell)
        }
        let anchorRange = NSRange(location: start + prompt.anchor.location, length: prompt.anchor.length)
        guard let anchor = try cellBounds(element, anchorRange) else { return .ineligible(.unreadable) }
        diagnostics.caretSource = .previousCharacter
        let caret = CGRect(x: anchor.maxX, y: anchor.minY, width: 1, height: anchor.height)
        let draftStart = try prompt.draftStart.flatMap { offset throws(AXFailure) in
            let cell = screen.rangeOfComposedCharacterSequence(at: offset)
            return try cellBounds(element, NSRange(location: start + cell.location, length: cell.length))
        } ?? caret
        let right = max(Self.frame(attributes)?.maxX ?? caret.maxX, caret.maxX)
        let fieldFrame = CGRect(
            x: draftStart.minX, y: draftStart.minY, width: right - draftStart.minX, height: caret.maxY - draftStart.minY
        )

        return .field(FieldSnapshot(
            id: FieldID(pid: app.identity.pid, elementHash: element.cfHash),
            app: app.identity,
            textBefore: prompt.textBefore,
            textAfter: prompt.textAfter,
            caretRect: caret,
            fieldFrame: fieldFrame,
            style: FieldStyle(fontName: Self.terminalFont),
            kind: .terminal,
            direction: FieldClassifier.direction(before: prompt.textBefore, after: prompt.textAfter),
            windowTitle: context.windowTitle,
            transcript: prompt.transcript
        ))
    }

    /// Orca draws its terminal on a canvas, so the text comes from Orca itself. xterm.js keeps its hidden input at the
    /// terminal cursor, one cell in size, which gives the caret and the cell size.
    private func readOrcaPrompt(_ context: FieldContext) throws(AXFailure) -> ReadResult {
        let element = context.element
        guard let cell = Self.frame(try element.values([kAXPositionAttribute, kAXSizeAttribute])) else {
            return .ineligible(.unreadable)
        }
        guard let terminal = OrcaRuntime.activeTerminal(pid: app.identity.pid, field: element.cfHash) else {
            return .ineligible(.terminalShell)
        }
        let screenFrame = try element.element(kAXParentAttribute)?.element(kAXParentAttribute)
            .flatMap { screen throws(AXFailure) in Self.frame(try screen.values([kAXPositionAttribute, kAXSizeAttribute])) }
        let caret = CGRect(x: cell.minX, y: cell.minY, width: 1, height: cell.height)
        let left = (screenFrame?.minX).map { $0 + 2 * cell.width } ?? caret.minX
        let right = max(screenFrame?.maxX ?? caret.maxX, caret.maxX)
        let screen = terminal.screen.joined(separator: "\n")
        let prompt = TerminalAgentPrompt.find(in: screen, cursor: nil)
        guard terminal.draft != nil || prompt != nil else { return .ineligible(.terminalShell) }
        let draft = terminal.draft ?? ""
        let transcript = prompt?.transcript ?? screen

        return .field(FieldSnapshot(
            id: FieldID(pid: app.identity.pid, elementHash: element.cfHash),
            app: app.identity,
            textBefore: draft,
            textAfter: "",
            caretRect: caret,
            fieldFrame: CGRect(x: min(left, caret.minX), y: caret.minY, width: right - min(left, caret.minX), height: caret.height),
            style: FieldStyle(fontName: Self.terminalFont),
            kind: .terminal,
            direction: FieldClassifier.direction(before: draft, after: ""),
            windowTitle: context.windowTitle,
            transcript: transcript
        ))
    }

    private func cellBounds(_ element: AXElement, _ range: NSRange) throws(AXFailure) -> CGRect? {
        guard let parameter = AXDecode.rangeValue(CFRange(location: range.location, length: range.length)),
              let rect = AXDecode.rect(try element.parameterized(kAXBoundsForRangeParameterizedAttribute, parameter)),
              rect.minX.isFinite, rect.minY.isFinite, rect.height > 0, rect.width > 0, rect.origin != .zero
        else { return nil }
        return rect
    }

    private func style(_ context: FieldContext, text: ExtractedText) throws(AXFailure) -> FieldStyle {
        guard case .range(let selection) = text.location else { return try CaretLocator.style(context.element, text: text) }
        let caret = selection.location + selection.length
        if let cached = Self.reusableStyle(context.style, at: caret) { return cached }
        let style = try CaretLocator.style(context.element, text: text)
        context.style = (caret, style)
        return style
    }

    /// A style read up to 3 characters before the caret still holds; further on it is read again, so a font change
    /// at the caret shows within a few typed characters. An empty style (read in an empty field, with no character
    /// before the caret) is read again as soon as the caret moves, or it would stick for the whole session.
    static func reusableStyle(_ cached: (caret: Int, value: FieldStyle)?, at caret: Int) -> FieldStyle? {
        guard let cached, (0...3).contains(caret - cached.caret), cached.value.fontName != nil || caret == cached.caret
        else { return nil }
        return cached.value
    }

    /// Chromium reports the font size but not the font. Measured once per focus, and again when the size changes;
    /// a caret line too short to measure is tried again on a later read.
    private func matchedFont(
        _ context: FieldContext, text: ExtractedText, size: Double, style: FieldStyle
    ) throws(AXFailure) -> String? {
        if let matched = context.matchedFont, matched.size == size { return matched.family }
        guard case .range(let selection) = text.location,
              let layout = try characterPositions(context.element, endingAt: selection.location, before: text.before)
        else { return nil }
        let family = FontMatcher.family(
            sample: layout.sample, positions: layout.positions, size: size, bold: style.isBold, italic: style.isItalic
        )
        context.matchedFont = (size, family)
        return family
    }

    private func characterPositions(
        _ element: AXElement, endingAt end: Int, before text: String
    ) throws(AXFailure) -> (sample: String, positions: [CGFloat])? {
        let line = text.lastIndex(where: \.isNewline).map { text[text.index(after: $0)...] } ?? text[...]
        let tail = line.suffix(32)
        guard tail.count >= FontMatcher.minSample,
              !tail.contains(where: { FieldClassifier.direction(of: $0) == .rightToLeft }) else { return nil }
        var rects: [CGRect] = []
        var location = end
        for character in tail.reversed() {
            location -= character.utf16.count
            guard location >= 0,
                  let parameter = AXDecode.rangeValue(CFRange(location: location, length: character.utf16.count)),
                  let rect = AXDecode.rect(try element.parameterized(kAXBoundsForRangeParameterizedAttribute, parameter))
            else { return nil }
            if let caretLine = rects.last, abs(rect.midY - caretLine.midY) > caretLine.height / 2 { break }
            rects.insert(rect, at: 0)
        }
        guard rects.count >= FontMatcher.minSample, let first = rects.first, let last = rects.last else { return nil }
        return (String(tail.suffix(rects.count)), rects.map { $0.minX - first.minX } + [last.maxX - first.minX])
    }

    /// Prompt inputs, such as a code editor's chat, start one line tall and grow as the user writes.
    static func isTooSmall(_ frame: CGRect, length: Int, kind: FieldKind, bundleID: String) -> Bool {
        guard length < 30, kind != .aiPrompt, !AppCatalog.ignoresSizeThresholds.contains(bundleID) else { return false }
        return (frame.height < 32 && frame.width < 300) || frame.width * frame.height < 6_400
    }

    private static func frame(_ attributes: [String: CFTypeRef]) -> CGRect? {
        guard let origin = AXDecode.point(attributes[kAXPositionAttribute]),
              let size = AXDecode.size(attributes[kAXSizeAttribute]),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

private struct Ancestry {
    private static let maxDepth = 40

    var outermostWebArea: AXElement?
    /// Frames included, so an extension frame inside a web page is seen.
    var webAreaURLs: [URL] = []
    var window: AXElement?
    var inSaveOrOpenPanel = false
    var domTokens: [String] = []
    var descriptions: Set<String> = []

    init(walkingUpFrom start: AXElement?) throws(AXFailure) {
        var current = start
        var depth = 0
        while let element = current, depth < Self.maxDepth {
            depth += 1
            let attributes = try element.values([
                kAXRoleAttribute, kAXParentAttribute, kAXIdentifierAttribute, AXName.domIdentifier,
                AXName.domClassList, kAXDescriptionAttribute, kAXURLAttribute,
            ])
            let role = AXDecode.string(attributes[kAXRoleAttribute])
            if role == AXName.webAreaRole {
                outermostWebArea = element
                if let url = AXDecode.url(attributes[kAXURLAttribute]) { webAreaURLs.append(url) }
            }
            let identifier = AXDecode.string(attributes[kAXIdentifierAttribute])
            if identifier == "save-panel" || identifier == "open-panel" { inSaveOrOpenPanel = true }
            if let domIdentifier = AXDecode.string(attributes[AXName.domIdentifier]) { domTokens.append(domIdentifier) }
            domTokens += AXDecode.strings(attributes[AXName.domClassList])
            if let description = AXDecode.nonEmptyString(attributes[kAXDescriptionAttribute]) {
                descriptions.insert(description)
            }
            if role == kAXWindowRole {
                window = element
                return
            }
            if role == kAXApplicationRole { return }
            current = AXDecode.element(attributes[kAXParentAttribute])
        }
    }
}

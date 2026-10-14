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

    let app: AppTarget
    let rule: AppRule
    let calibration: CaretCalibration

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
        if SecretFieldHints.isCredentialAutofill(AXDecode.string(attributes[AXName.valueAutofillType])) {
            return rejected(.secureField)
        }
        let isEditableWeb = attributes[kAXEditableAncestorAttribute] != nil
        guard Self.textRoles.contains(role) || isEditableWeb else { return rejected(.notTextInput) }
        let label = try label(attributes)
        let labels = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { AXDecode.string(attributes[$0]) }
            + AXDecode.strings(attributes[AXName.userInputLabels]) + [label].compactMap { $0 }
        if labels.contains(where: SecretFieldHints.mentionsPassword) { return rejected(.secureField) }
        if subrole == kAXSearchFieldSubrole { return rejected(.searchField) }

        let ancestry = try Ancestry(walkingUpFrom: AXDecode.element(attributes[kAXParentAttribute]))
        let webArea = role == AXName.webAreaRole ? element : ancestry.outermostWebArea
        let bundleID = app.identity.bundleID

        if AppCatalog.browsers.contains(bundleID), webArea == nil { return rejected(.addressBar) }
        let identifier = AXDecode.string(attributes[kAXIdentifierAttribute]) ?? ""
        if Self.mailAddressFields.contains(identifier) || ancestry.inSaveOrOpenPanel { return rejected(.excludedField) }

        let isTerminal = BuiltInAppRules.isTerminal(bundleID)
        if isTerminal, rule.completionsEnabled != true { return rejected(.terminalShell) }

        var isAgentComposer = false
        var isCodeEditor = AppCatalog.isCodeEditor(bundleID)
        if AppCatalog.vsCodeForks.contains(bundleID) {
            if domClasses.contains("xterm-helper-textarea") { return rejected(.terminalShell) }
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
            host: webArea == nil ? nil : context.url?.host().map(DomainPattern.normalize),
            isWeb: webArea != nil,
            isTerminal: isTerminal,
            isCodeEditor: isCodeEditor,
            isAgentComposer: isAgentComposer
        ))
        return context
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
            language: context.language
        ))
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

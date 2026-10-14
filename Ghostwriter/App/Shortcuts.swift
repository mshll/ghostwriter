import AppKit
import Input
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    private static let keyAboveTab = KeyboardShortcuts.Key(rawValue: Int(KeyboardLayout.keyAboveTab))

    static let toggleCompletions = Self("toggleCompletions", initial: .init(keyAboveTab, modifiers: [.control, .option]))
    static let toggleCompletionsInApp = Self(
        "toggleCompletionsInApp", initial: .init(keyAboveTab, modifiers: [.control, .option, .command])
    )
    static let selectionActions = Self("selectionActions", initial: .init(keyAboveTab, modifiers: [.option, .shift]))
    static let longDraft = Self("longDraft", initial: .init(keyAboveTab, modifiers: [.option]))
    static let forceComplete = Self("forceComplete", initial: .init(keyAboveTab, modifiers: [.control]))
    static let proofread = Self("proofread", initial: .init(keyAboveTab, modifiers: [.option, .command]))
    static let global: [Self] = [.toggleCompletions, .toggleCompletionsInApp, .forceComplete, .longDraft, .selectionActions, .proofread]
}

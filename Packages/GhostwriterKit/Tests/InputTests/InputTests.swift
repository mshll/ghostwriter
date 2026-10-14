import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GWCore
import Testing
@testable import Input

@Suite struct WordSplitterTests {
    private func chunk(_ text: String, space: Bool = false, punctuation: Bool = true) -> String {
        WordSplitter.nextChunk(of: text, includeTrailingSpace: space, includeTrailingPunctuation: punctuation)
    }

    @Test func takesLeadingSpaceAndNextWord() {
        #expect(chunk(" my previous email") == " my")
        #expect(chunk("my previous email") == "my")
    }

    @Test func trailingSpaceAppendsFollowingSpaces() {
        #expect(chunk(" my previous", space: true) == " my ")
        #expect(chunk("word  next", space: true) == "word  ")
        #expect(chunk("end", space: true) == "end")
    }

    @Test func trailingSpaceStopsAtNewline() {
        #expect(chunk("end.\n\nNext", space: true) == "end.")
    }

    @Test func punctuationAttachedWhenOn() {
        #expect(chunk(" it.") == " it.")
        #expect(chunk(" 15% compared") == " 15%")
        #expect(chunk(" merge it?", space: true) == " merge ")
        #expect(chunk("wait... what") == "wait...")
    }

    @Test func splitsBeforePunctuationWhenOff() {
        #expect(chunk(" 15% compared", punctuation: false) == " 15")
        #expect(chunk(" it.", punctuation: false) == " it")
        #expect(chunk("wait...", punctuation: false) == "wait")
    }

    @Test func punctuationOnlyRunIsOneChunk() {
        #expect(chunk("% compared", punctuation: false) == "%")
        #expect(chunk(", and then", punctuation: false) == ",")
        #expect(chunk(" — and") == " —")
    }

    @Test func internalPunctuationStaysInWord() {
        #expect(chunk("it's fine", punctuation: false) == "it's")
        #expect(chunk("well-known, really", punctuation: false) == "well-known")
        #expect(chunk("well-known, really") == "well-known,")
    }

    @Test func numbers() {
        #expect(chunk(" 3.14, then", punctuation: false) == " 3.14")
        #expect(chunk(" 1,000 people") == " 1,000")
        #expect(chunk(" November 15, 2026") == " November")
        #expect(chunk(" 15, 2026") == " 15,")
        #expect(chunk(" $5.00.", punctuation: false) == " $5.00")
    }

    @Test func emojiAreWordsNotPunctuation() {
        #expect(chunk(" 👍🏽 thanks") == " 👍🏽")
        #expect(chunk(" 🇸🇦 flag", punctuation: false) == " 🇸🇦")
        #expect(chunk(" great❤️ thanks", punctuation: false) == " great❤️")
    }

    @Test func arabic() {
        #expect(chunk(" مرحبا بالعالم") == " مرحبا")
        #expect(chunk(" مرحبا، كيف") == " مرحبا،")
        #expect(chunk(" مرحبا، كيف", punctuation: false) == " مرحبا")
        #expect(chunk(" حالك؟", punctuation: false) == " حالك")
    }

    @Test func japaneseAdvancesOneWord() {
        #expect(chunk("今日はいい天気ですね。") == "今日")
        #expect(chunk("ですね。") == "です")
        #expect(chunk("ね。") == "ね。")
        #expect(chunk("ね。", punctuation: false) == "ね")
    }

    @Test func chineseAndThai() {
        #expect(chunk("我们明天见。") == "我们")
        #expect(chunk("สวัสดีครับ") == "สวัสดี")
    }

    @Test func mixedScriptRunStopsAtScriptChange() {
        #expect(chunk("AppleのiPhone") == "Apple")
    }

    @Test func emptyAndWhitespaceOnly() {
        #expect(chunk("") == "")
        #expect(chunk("  ") == "  ")
    }

    @Test func repeatedPressesRebuildTheSuggestion() {
        let suggestion = " 15% compared to the previous quarter."
        for punctuation in [true, false] {
            var rest = Substring(suggestion)
            var pieces: [String] = []
            while !rest.isEmpty {
                let piece = WordSplitter.nextChunk(of: String(rest), includeTrailingSpace: false, includeTrailingPunctuation: punctuation)
                #expect(!piece.isEmpty)
                pieces.append(piece)
                rest = rest.dropFirst(piece.count)
            }
            #expect(pieces.joined() == suggestion)
        }
    }
}

@Suite struct ChunkingTests {
    @Test func asciiSplitsAtLimit() {
        let text = String(repeating: "a", count: 45)
        #expect(TextInserter.chunks(of: text, limit: 20).map(\.count) == [20, 20, 5])
    }

    @Test func surrogatePairsAreNotSplit() {
        let text = String(repeating: "a", count: 19) + "😀b"
        let chunks = TextInserter.chunks(of: text, limit: 20)
        #expect(chunks == [String(repeating: "a", count: 19), "😀b"])
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
    }

    @Test func flagsAndFamiliesStayWhole() {
        let family = "👨‍👩‍👧‍👦"
        let text = "ab🇸🇦" + family + "cd"
        let chunks = TextInserter.chunks(of: text, limit: 8)
        #expect(chunks.joined() == text)
        #expect(chunks.contains { $0.contains(family) })
        #expect(chunks.contains { $0.contains("🇸🇦") })
    }

    @Test func combiningMarksStayWithBase() {
        let decomposed = "e\u{301}"
        let text = String(repeating: decomposed, count: 15)
        let chunks = TextInserter.chunks(of: text, limit: 3)
        #expect(chunks.allSatisfy { $0 == decomposed })
    }

    @Test func clusterLongerThanChunkTravelsAlone() {
        let chunks = TextInserter.chunks(of: "a😀b", limit: 1)
        #expect(chunks == ["a", "😀", "b"])
    }

    @Test func limitBelowOneSendsOneClusterPerEvent() {
        #expect(TextInserter.chunks(of: "abc", limit: 0) == ["a", "b", "c"])
    }

    @Test func largeLimitIsHonoured() {
        let text = String(repeating: "x", count: 50)
        #expect(TextInserter.chunks(of: text, limit: 40).map(\.count) == [40, 10])
    }

    @Test func oversizedClusterStaysWhole() {
        let zalgo = "a" + String(repeating: "\u{301}", count: 30)
        #expect(TextInserter.chunks(of: zalgo + "b", limit: 20) == [zalgo, "b"])
    }

    @Test func arabicKeepsDiacritics() {
        let text = "مَرْحَبًا بِكُمْ"
        let chunks = TextInserter.chunks(of: text, limit: 4)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 4 })
    }
}

@Suite struct KeyClassificationTests {
    @Test func cgFlagsMapToModifierFlags() {
        let pairs: [(CGEventFlags, NSEvent.ModifierFlags)] = [
            (.maskShift, .shift), (.maskControl, .control), (.maskAlternate, .option),
            (.maskCommand, .command), (.maskAlphaShift, .capsLock), (.maskSecondaryFn, .function),
        ]
        for (flags, expected) in pairs {
            #expect(KeyEvent.modifiers(from: flags) == expected.rawValue)
        }
        #expect(KeyEvent.modifiers(from: [.maskCommand, .maskShift]) == NSEvent.ModifierFlags([.command, .shift]).rawValue)
    }

    @Test func deviceDependentBitsAreDropped() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0008)
        #expect(KeyEvent.modifiers(from: flags) == NSEvent.ModifierFlags.command.rawValue)
    }

    @Test func kinds() {
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a") == .character)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_A), modifiers: .shift, characters: "A") == .character)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_A), modifiers: .option, characters: "å") == .character)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_C), modifiers: .command, characters: "c") == .shortcut)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_A), modifiers: .control, characters: "\u{1}") == .shortcut)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_Delete), modifiers: [], characters: "\u{7F}") == .deleteBackward)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_Delete), modifiers: .option, characters: "\u{7F}") == .deleteBackward)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ForwardDelete), modifiers: [], characters: "") == .deleteForward)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_Return), modifiers: [], characters: "\r") == .returnKey)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: [], characters: "\u{3}") == .returnKey)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_Tab), modifiers: [], characters: "\t") == .tab)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_Escape), modifiers: [], characters: "\u{1B}") == .escape)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_LeftArrow), modifiers: [], characters: "\u{1C}") == .navigation)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_LeftArrow), modifiers: .command, characters: "\u{1C}") == .navigation)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_PageDown), modifiers: [], characters: "") == .navigation)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_F5), modifiers: [], characters: "\u{10}") == .other)
        #expect(KeyEvent.kind(keyCode: UInt16(kVK_ANSI_E), modifiers: .option, characters: "") == .other)
    }

    @Test func eventsWithTheMarkerAreIgnored() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true))
        let units: [UniChar] = Array("a".utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        #expect(KeyEvent(event)?.kind == .character)
        #expect(KeyEvent(event)?.characters == "a")
        event.setIntegerValueField(.eventSourceUserData, value: EventMarker.userData)
        #expect(KeyEvent(event) == nil)
    }
}

@Suite struct HotKeyTests {
    @Test func modifierFlagsRoundTripThroughCarbonMask() {
        let all: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let hotKey = HotKey(keyCode: UInt16(kVK_Tab), modifierFlags: all)
        #expect(hotKey.modifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(hotKey.modifierFlags == all)
        #expect(HotKey(keyCode: 48, modifierFlags: [.capsLock, .function]).modifiers == 0)
        #expect(HotKey.optionTab.modifierFlags == .option)
    }

    @Test func digits() {
        #expect(HotKey.digit(1)?.keyCode == UInt32(kVK_ANSI_1))
        #expect(HotKey.digit(9)?.keyCode == UInt32(kVK_ANSI_9))
        #expect(HotKey.digit(0) == nil)
        #expect(HotKey.digit(10) == nil)
    }

    @MainActor @Test func displayStrings() {
        #expect(HotKey.tab.displayString == "⇥")
        #expect(HotKey.optionTab.displayString == "⌥⇥")
        #expect(HotKey(keyCode: UInt16(kVK_Escape), modifierFlags: [.command, .shift, .control]).displayString == "⌃⇧⌘⎋")
        #expect(!HotKey.keyAboveTab.displayString.isEmpty)
    }

    @Test func keyAboveTabIsIsoOrAnsi() async {
        let code = await Task.detached { KeyboardLayout.keyAboveTab }.value
        #expect(code == 10 || code == 50)
    }
}

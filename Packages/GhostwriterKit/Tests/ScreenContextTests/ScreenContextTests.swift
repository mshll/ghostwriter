import CoreGraphics
import Foundation
import Testing
import ScreenCaptureKit
@testable import ScreenContext

@Suite struct ClipboardClassifier {
    @Test(arguments: [
        "Can we move the review to Thursday afternoon?",
        "https://example.com",
        "https://www.example.com/blog/2026/10/notes-from-the-offsite",
        "https://youtu.be/dQw4w9WgXcQ",
        "supercalifragilisticexpialidocious",
        "/Users/sam/Documents/Quarterly-Report.pdf",
        "McDonald's opened at 7 am, said the U.S.-based manager.",
        "Absolutely! Let's do it.",
    ])
    func keepsProseAndPlainLinks(_ text: String) {
        #expect(ClipboardReader.isUsable(text))
    }

    @Test(arguments: [
        "",
        "483920",
        "hunter2",
        "Xk9#mP2$vL8@qR4!wT6z",
        "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
        String(repeating: "3f2a9c1e", count: 5),
        "sk-proj-" + String(repeating: "aB3d", count: 8),
        "ghp_" + String(repeating: "a1B2", count: 9),
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl",
        "https://sam:secret@example.com/admin",
        "https://example.com/reset?token=" + String(repeating: "8f7a6b5c", count: 4),
        "Here is the key sk-live-" + String(repeating: "Zx9Q", count: 6) + " for the staging server",
        "The guest wifi password is Tr0ub4dor&3 until Friday",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE\n-----END OPENSSH PRIVATE KEY-----",
    ])
    func dropsSecrets(_ text: String) {
        #expect(!ClipboardReader.isUsable(text))
    }
}

@Suite struct Cleaning {
    @Test(arguments: ["明日の会議は十時からです", "我们下周再讨论预算", "สวัสดีครับทุกคน"])
    func shortLinesWithoutSpacesAreKept(_ line: String) {
        #expect(ScreenText.cleaned(line) == line)
    }

    @Test(arguments: ["ファイル", "Settings", "12:45"])
    func singleShortWordsAreDropped(_ line: String) {
        #expect(ScreenText.cleaned(line) == nil)
    }
}

@Suite struct WindowReadsTests {
    private let window = WindowKey(pid: 42, frame: CGRect(x: 0, y: 25, width: 1200, height: 800))
    private let start = ContinuousClock.now
    private let above = TextChunk(text: "Earlier message in the thread", frame: CGRect(x: 40, y: 200, width: 500, height: 40))
    private let inField = TextChunk(text: "Draft the field holds", frame: CGRect(x: 40, y: 700, width: 500, height: 20))

    @Test func fieldsShareTheWindowTextWithoutTheirOwn() {
        var reads = WindowReads()
        reads.store([above, inField], of: window, at: start)
        let field = CGRect(x: 30, y: 690, width: 700, height: 60)
        #expect(reads.chunks(of: window, outside: field, at: start + .seconds(1)) == [above])
        #expect(reads.chunks(of: window, outside: .zero, at: start + .seconds(1)) == [above, inField])
    }

    @Test func readsAWindowAgainOnlyAfterTheInterval() {
        var reads = WindowReads()
        #expect(reads.allowsRead(of: window, at: start))
        reads.store([above], of: window, at: start)
        #expect(!reads.allowsRead(of: window, at: start + .seconds(29)))
        #expect(reads.allowsRead(of: window, at: start + WindowReads.rereadAfter))
    }

    @Test func textExpiresAndWindowsAreSeparate() {
        var reads = WindowReads()
        let other = WindowKey(pid: 43, frame: CGRect(x: 0, y: 25, width: 1200, height: 800))
        reads.store([above], of: window, at: start)
        #expect(reads.chunks(of: window, outside: .zero, at: start + WindowReads.lifetime) == nil)
        #expect(reads.chunks(of: other, outside: .zero, at: start) == nil)
        #expect(reads.allowsRead(of: other, at: start))
    }
}

@Suite struct OCRSlotTests {
    private let start = ContinuousClock.now

    @Test func oneOCRAtATime() {
        var slot = OCRSlot()
        let first = slot.claim(at: start)
        let second = slot.claim(at: start + .seconds(1))
        slot.release(start)
        let afterRelease = slot.claim(at: start + .seconds(2))
        #expect(first == .granted)
        #expect(second == .busy)
        #expect(afterRelease == .granted)
    }

    @Test func aStuckOCRStopsBlockingAndCannotFreeItsSuccessor() {
        var slot = OCRSlot()
        _ = slot.claim(at: start)
        let late = start + OCRSlot.stuckAfter
        let taken = slot.claim(at: late)
        slot.release(start)
        let afterStaleRelease = slot.claim(at: late + .seconds(1))
        #expect(taken == .takenFromStuck)
        #expect(afterStaleRelease == .busy)
    }
}

@Suite struct OCRLanguageTests {
    private let supported = ["en-US", "fr-FR", "ar-SA", "zh-Hans", "zh-Hant", "ja-JP"].map(Locale.Language.init(identifier:))

    private func languages(_ language: String?) -> [Locale.Language]? {
        WindowOCR.recognitionLanguages(for: language, supported: supported)
    }

    private func expected(_ identifiers: String...) -> [Locale.Language] {
        identifiers.map(Locale.Language.init(identifier:))
    }

    @Test func readsTheFieldLanguageAndEnglish() {
        #expect(languages("ar") == expected("ar-SA", "en-US"))
        #expect(languages("fr-CA") == expected("fr-FR", "en-US"))
        #expect(languages("zh-Hant") == expected("zh-Hant", "en-US"))
        #expect(languages("zh-TW") == expected("zh-Hant", "en-US"))
    }

    @Test func englishAloneForEnglishFields() {
        #expect(languages("en-GB") == expected("en-US"))
    }

    @Test func detectsLanguagesWhenUnknownOrUnsupported() {
        #expect(languages(nil) == nil)
        #expect(languages("he") == nil)
    }

    @Test func warmsAutomaticDetectionThenEachConfigurationOnce() {
        let configurations = OCRWarmUp.configurations(for: ["en", "en-US", "ar-US", "he", "en-GB"], supported: supported)
        #expect(configurations == [nil, expected("en-US"), expected("ar-SA", "en-US")])
    }
}

@Suite struct CaptureRegionTests {
    private let window = CGRect(x: 100, y: 50, width: 1400, height: 1300)

    @Test func tallWindowsAreCroppedAroundTheCaret() {
        let caret = CGRect(x: 600, y: 900, width: 1, height: 18)
        let region = WindowOCR.captureRegion(window: window, caret: caret)
        #expect(region == CGRect(x: 100, y: 300, width: 1400, height: 818))
    }

    @Test func bandStopsAtTheWindowEdge() {
        let caret = CGRect(x: 600, y: 1300, width: 1, height: 18)
        let region = WindowOCR.captureRegion(window: window, caret: caret)
        #expect(region == CGRect(x: 100, y: 700, width: 1400, height: 650))
    }

    @Test func smallWindowsAreReadWhole() {
        let small = CGRect(x: 100, y: 50, width: 900, height: 700)
        let caret = CGRect(x: 400, y: 400, width: 1, height: 18)
        #expect(WindowOCR.captureRegion(window: small, caret: caret) == small)
    }

    @Test func caretOutsideTheWindowReadsItWhole() {
        let caret = CGRect(x: 2000, y: 3000, width: 1, height: 18)
        #expect(WindowOCR.captureRegion(window: window, caret: caret) == window)
    }
}

@Suite struct WindowMatchTests {
    private let frames = [
        CGRect(x: 0, y: 30, width: 800, height: 600),
        CGRect(x: 156, y: 91, width: 1200, height: 800),
        CGRect(x: 900, y: 100, width: 500, height: 400),
    ]
    private let field = CGRect(x: 1000, y: 300, width: 200, height: 40)

    @Test func matchesTheSameFrame() {
        #expect(WindowOCR.matchingWindow(frames, windowFrame: frames[1], mask: field) == 1)
    }

    @Test func allowsASmallDrift() {
        let drifted = CGRect(x: 158, y: 92, width: 1198, height: 806)
        #expect(WindowOCR.matchingWindow(frames, windowFrame: drifted, mask: field) == 1)
    }

    @Test func rejectsAWindowFarFromTheFrame() {
        let elsewhere = CGRect(x: 300, y: 200, width: 1000, height: 700)
        #expect(WindowOCR.matchingWindow(frames, windowFrame: elsewhere, mask: field) == nil)
        #expect(WindowOCR.matchingWindow([], windowFrame: frames[1], mask: field) == nil)
    }

    @Test func withoutAFrameTakesTheWindowAroundTheField() {
        #expect(WindowOCR.matchingWindow(frames, windowFrame: .zero, mask: field) == 2)
        let nowhere = CGRect(x: 2000, y: 2000, width: 10, height: 10)
        #expect(WindowOCR.matchingWindow(frames, windowFrame: .zero, mask: nowhere) == nil)
    }
}

@Suite struct CaptureDeclineTests {
    @Test func recognizesADeclinedCapture() {
        #expect(WindowOCR.isDeclined(SCStreamError(.userDeclined)))
        #expect(!WindowOCR.isDeclined(SCStreamError(.failedToStart)))
        #expect(!WindowOCR.isDeclined(WindowOCRError.windowNotFound))
    }
}

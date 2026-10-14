import ApplicationServices
import Foundation
import GWCore
import Testing
@testable import Capture

@Suite struct SecretFieldHintsTests {
    @Test func passwordInEachLanguage() {
        let labels = [
            "Password", "Passcode", "Passwort", "Mot de passe", "Contraseña", "Senha", "Wachtwoord", "Пароль",
            "كلمة المرور", "كلمة السر", "パスワード", "密码", "密碼", "비밀번호",
        ]
        for label in labels {
            #expect(SecretFieldHints.mentionsPassword(label), "\(label)")
        }
    }

    @Test func matchesInsideLongerLabels() {
        #expect(SecretFieldHints.mentionsPassword("Enter your password"))
        #expect(SecretFieldHints.mentionsPassword("Confirm new passcode:"))
        #expect(SecretFieldHints.mentionsPassword("Введите пароль"))
    }

    @Test func ignoresCaseDiacriticsAndWidth() {
        #expect(SecretFieldHints.mentionsPassword("PASSWORD"))
        #expect(SecretFieldHints.mentionsPassword("MOT DE PASSE"))
        #expect(SecretFieldHints.mentionsPassword("contrasena"))
        #expect(SecretFieldHints.mentionsPassword("ＰＡＳＳＷＯＲＤ"))
    }

    @Test func ordinaryLabelsAreNotSecret() {
        for label in ["Message", "Passport number", "Subject", "Search", "Compass heading", "Password-free", ""] {
            #expect(SecretFieldHints.mentionsPassword(label) == (label == "Password-free"), "\(label)")
        }
    }

    @Test func credentialAutofill() {
        #expect(SecretFieldHints.isCredentialAutofill("credentials"))
        #expect(SecretFieldHints.isCredentialAutofill("strong password"))
        for other in ["contacts", "credit card", "loading", "none"] {
            #expect(!SecretFieldHints.isCredentialAutofill(other), "\(other)")
        }
        #expect(!SecretFieldHints.isCredentialAutofill(nil))
    }
}

@Suite struct FieldSizeTests {
    private let chatInput = CGRect(x: 64, y: 810, width: 248, height: 20)

    @Test func smallEmptyFieldIsTooSmall() {
        #expect(FieldReader.isTooSmall(chatInput, length: 0, kind: .unknown, bundleID: "com.example.app"))
        #expect(!FieldReader.isTooSmall(chatInput, length: 30, kind: .unknown, bundleID: "com.example.app"))
    }

    @Test func promptInputOfAnyHeightIsLargeEnough() {
        #expect(!FieldReader.isTooSmall(chatInput, length: 0, kind: .aiPrompt, bundleID: "com.microsoft.VSCode"))
    }
}

@Suite struct PageSchemeTests {
    private func readable(_ string: String, inBrowser: Bool) throws -> Bool {
        PageScheme.isReadable(try #require(URL(string: string)), inBrowser: inBrowser)
    }

    @Test func browsersReadWebPagesOnly() throws {
        for page in ["https://example.com/", "http://example.com", "file:///tmp/a.html", "about:blank", "HTTPS://example.com"] {
            #expect(try readable(page, inBrowser: true), "\(page)")
        }
        let notPages = [
            "chrome-extension://abcdef/popup.html", "safari-web-extension://1234/popup.html",
            "moz-extension://1234/popup.html", "extension://abcdef/popup.html", "chrome://settings",
            "edge://settings", "data:text/html,hi",
        ]
        for page in notPages {
            #expect(try !readable(page, inBrowser: true), "\(page)")
        }
    }

    @Test func otherAppsRefuseExtensionPagesOnly() throws {
        for page in ["vscode-file://vscode-app/workbench.html", "app://obsidian.md/index.html", "file:///tmp/a.txt"] {
            #expect(try readable(page, inBrowser: false), "\(page)")
        }
        #expect(try !readable("chrome-extension://abcdef/popup.html", inBrowser: false))
    }

    @Test func urlWithoutSchemeIsReadable() throws {
        #expect(try readable("relative/path", inBrowser: true))
    }
}

@Suite struct WebAccessibilityTests {
    private let start = ContinuousClock.now

    @Test func writesAgainOnlyAfterTheAppsDelay() {
        #expect(WebAccessibility.isDue(lastWrite: nil, now: start))
        #expect(!WebAccessibility.isDue(lastWrite: start, now: start + .seconds(2)))
        #expect(WebAccessibility.isDue(lastWrite: start, now: start + WebAccessibility.rewriteInterval))
    }

    @Test func successIsWritten() {
        #expect(WebAccessibility.isWritten(.success, attribute: AXName.manualAccessibility) { nil })
    }

    @Test func notImplementedCountsWhenTheEnhancedFlagReadsBackTrue() {
        let attribute = AXName.enhancedUserInterface
        #expect(WebAccessibility.isWritten(.notImplemented, attribute: attribute) { true })
        #expect(!WebAccessibility.isWritten(.notImplemented, attribute: attribute) { false })
        #expect(!WebAccessibility.isWritten(.notImplemented, attribute: attribute) { nil })
    }

    @Test func otherFailuresAreNotWritten() {
        var readBack = false
        #expect(!WebAccessibility.isWritten(.notImplemented, attribute: AXName.manualAccessibility) {
            readBack = true
            return true
        })
        #expect(!readBack)
        #expect(!WebAccessibility.isWritten(.attributeUnsupported, attribute: AXName.enhancedUserInterface) { true })
    }
}

@Suite struct EnhancedUserInterfaceFallbackTests {
    private let start = ContinuousClock.now

    @Test func allowsOneWriteAfterTheRoleReadSettles() {
        var fallback = EnhancedUserInterfaceFallback()
        fallback.arm(pid: 7, at: start, allowed: true)
        let takes = [start, start + EnhancedUserInterfaceFallback.settle, start + .seconds(5)].map {
            fallback.take(pid: 7, at: $0)
        }
        #expect(takes == [false, true, false])
    }

    @Test func refusesOtherProcessesAndDisallowedApps() {
        var fallback = EnhancedUserInterfaceFallback()
        fallback.arm(pid: 7, at: start, allowed: true)
        let otherProcess = fallback.take(pid: 8, at: start + .seconds(1))
        fallback.arm(pid: 7, at: start, allowed: false)
        let disallowed = fallback.take(pid: 7, at: start + .seconds(1))
        #expect(!otherProcess)
        #expect(!disallowed)
    }
}

@Suite struct PreparationRetryTests {
    private let start = ContinuousClock.now

    private func attemptTimes() -> [Duration] {
        var retry = PreparationRetry(pid: 7, steps: [.readRole], at: start)
        var times: [Duration] = []
        var now = start
        while !retry.isExpired(at: now) {
            if retry.isDue(at: now) {
                times.append(now - start)
                retry.failed([.readRole], at: now)
            }
            now += .milliseconds(50)
        }
        return times
    }

    @Test func backsOffUpToTwoSecondsForTenSeconds() {
        let seconds = attemptTimes().map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        #expect(seconds == [0.25, 0.75, 1.75, 3.75, 5.75, 7.75, 9.75])
    }

    @Test func keepsOnlyTheUnansweredSteps() {
        var retry = PreparationRetry(pid: 7, steps: [.readRole, .enhancedUserInterface, .appNotifications], at: start)
        retry.failed([.enhancedUserInterface], at: start + .milliseconds(250))
        #expect(retry.steps == [.enhancedUserInterface])
        #expect(retry.attempts == 1)
        #expect(!retry.isDue(at: start + .milliseconds(500)))
        #expect(retry.isDue(at: start + .milliseconds(750)))
    }
}

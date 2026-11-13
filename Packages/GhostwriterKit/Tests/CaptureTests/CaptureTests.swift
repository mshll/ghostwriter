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

@Suite struct PaymentFieldHintsTests {
    @Test func cardLabelsInEachLanguage() {
        let labels = [
            "Card number", "Credit card", "Debit card number", "CVV", "CVC", "CSC", "CVV2", "Security code",
            "Expiration date", "Expiry date", "MM / YY", "MM/YYYY",
            "رقم البطاقة", "بطاقة الائتمان", "رمز الأمان", "تاريخ الانتهاء",
            "Numéro de carte", "Carte bancaire", "Carte de crédit", "Cryptogramme visuel", "Date d’expiration", "MM/AA",
            "Kartennummer", "Kreditkarte", "Prüfnummer", "Sicherheitscode", "Ablaufdatum", "Gültig bis", "MM/JJ",
            "Número de tarjeta", "Tarjeta de crédito", "Código de seguridad", "Fecha de vencimiento",
            "Fecha de caducidad",
        ]
        for label in labels {
            #expect(SecretFieldHints.namesPaymentOrOneTimeCode(label), "\(label)")
        }
    }

    @Test func oneTimeCodeLabelsInEachLanguage() {
        let labels = [
            "One-time code", "One time passcode", "Verification code", "Enter the OTP", "2FA code",
            "Authentication code", "رمز التحقق", "رمز لمرة واحدة", "Code de vérification", "Code à usage unique",
            "Bestätigungscode", "Einmalcode", "Código de verificación",
        ]
        for label in labels {
            #expect(SecretFieldHints.namesPaymentOrOneTimeCode(label), "\(label)")
        }
    }

    @Test func cardNumberPlaceholder() {
        #expect(SecretFieldHints.namesPaymentOrOneTimeCode("1234 1234 1234 1234"))
        #expect(SecretFieldHints.namesPaymentOrOneTimeCode("0000-0000-0000-0000"))
        #expect(!SecretFieldHints.namesPaymentOrOneTimeCode("2024"))
        #expect(!SecretFieldHints.namesPaymentOrOneTimeCode("+1 555 0100"))
    }

    @Test func webIdentifiers() {
        let identifiers = [
            "cc-number", "ccNumber", "card_number", "cardnumber", "cc-csc", "cvc", "card-cvv", "cc-exp",
            "expiry-date", "one-time-code", "otpInput", "securityCode", "checkout_card_number_field",
        ]
        for identifier in identifiers {
            #expect(SecretFieldHints.namesPaymentOrOneTimeCode(identifier), "\(identifier)")
        }
    }

    @Test func ordinaryFieldsAreNotPayment() {
        let names = [
            "Message", "Code", "Source code", "Card title", "Add a card", "Gift card message", "Postal code",
            "Promo code", "Country code", "footprint", "hotpot", "discard-number", "successExpected",
            "Expires in", "Expiration reminder", "Subject", "Message #cards", "editor", "monaco-editor",
            "Comment", "Phone number", "", "رسالة", "Nachricht", "Carte du restaurant",
        ]
        for name in names {
            #expect(!SecretFieldHints.namesPaymentOrOneTimeCode(name), "\(name)")
        }
    }

    @Test func cardAutofill() {
        #expect(SecretFieldHints.isPaymentAutofill("credit card"))
        for other in ["credentials", "contacts", "strong password", "loading", "none"] {
            #expect(!SecretFieldHints.isPaymentAutofill(other), "\(other)")
        }
        #expect(!SecretFieldHints.isPaymentAutofill(nil))
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

@Suite struct SingleWordTests {
    private func snapshot(_ before: String) -> FieldSnapshot {
        FieldSnapshot(
            id: FieldID(pid: 1, elementHash: 1),
            app: AppIdentity(bundleID: "test", name: "Test", pid: 1),
            textBefore: before,
            textAfter: "",
            caretRect: .zero,
            fieldFrame: .zero
        )
    }

    @Test func oneWordWithoutSpaceIsSingle() {
        for text in ["", "meshal", "meshal.alfa@gmai", "Hello,", "+1-555-0100", "https://example.com", "مرحبا"] {
            #expect(snapshot(text).isSingleWord, "\(text)")
        }
    }

    @Test func anyWhitespaceEndsSingleWord() {
        for text in ["Dear ", "Hi there", "Meshal Al", "Hello\n", "line\tone", "a\u{00A0}b"] {
            #expect(!snapshot(text).isSingleWord, "\(text)")
        }
    }

    @Test func scriptsWrittenWithoutSpacesAreNotSingle() {
        for text in ["今日は", "我想", "สวัสดี", "カタカナ"] {
            #expect(!snapshot(text).isSingleWord, "\(text)")
        }
    }
}

@Suite struct EmptyLineCaretTests {
    private let field = CGRect(x: 408, y: 832, width: 710, height: 76)

    @Test func lineBoxBecomesCaretAtLineStart() {
        let box = CGRect(x: 412, y: 881, width: 702, height: 23)
        #expect(CaretLocator.emptyLineCaret(box, in: field, rightToLeft: false) == CGRect(x: 412, y: 881, width: 1, height: 23))
    }

    @Test func rightToLeftCaretSitsAtLineEnd() {
        let box = CGRect(x: 412, y: 881, width: 702, height: 23)
        #expect(CaretLocator.emptyLineCaret(box, in: field, rightToLeft: true) == CGRect(x: 1114, y: 881, width: 1, height: 23))
    }

    @Test func boxOutsideTheFieldIsRejected() {
        let window = CGRect(x: 30, y: 55, width: 1425, height: 939)
        #expect(CaretLocator.emptyLineCaret(window, in: field, rightToLeft: false) == nil)
    }

    @Test func unknownFieldIsRejected() {
        #expect(CaretLocator.emptyLineCaret(CGRect(x: 412, y: 881, width: 702, height: 23), in: nil, rightToLeft: false) == nil)
    }

    @Test func narrowRectIsLeftToTheCaretChecks() {
        #expect(CaretLocator.emptyLineCaret(CGRect(x: 412, y: 881, width: 0, height: 17), in: field, rightToLeft: false) == nil)
    }
}
